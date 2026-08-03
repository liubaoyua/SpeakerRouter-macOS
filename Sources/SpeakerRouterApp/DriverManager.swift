import Foundation

enum DriverInstallationState: Equatable {
  case checking
  case bundledDriverMissing
  case notInstalled(bundledVersion: String)
  case installed(version: String)
  case updateAvailable(installedVersion: String, bundledVersion: String)
  case changing(message: String)

  var description: String {
    switch self {
    case .checking:
      return "正在检查…"
    case .bundledDriverMissing:
      return "当前 App 未包含驱动"
    case .notInstalled(let bundledVersion):
      return "未安装（可安装 v\(bundledVersion)）"
    case .installed(let version):
      return "已安装 v\(version)"
    case .updateAvailable(let installedVersion, let bundledVersion):
      return "v\(installedVersion) → v\(bundledVersion)"
    case .changing(let message):
      return message
    }
  }

  var primaryActionTitle: String? {
    switch self {
    case .notInstalled:
      return "安装驱动"
    case .installed:
      return "重新安装"
    case .updateAvailable:
      return "更新驱动"
    case .checking, .bundledDriverMissing, .changing:
      return nil
    }
  }

  var canUninstall: Bool {
    switch self {
    case .installed, .updateAvailable:
      return true
    case .checking, .bundledDriverMissing, .notInstalled, .changing:
      return false
    }
  }

  var isChanging: Bool {
    if case .changing = self {
      return true
    }
    return false
  }
}

enum DriverManagerAction: String {
  case install
  case uninstall
}

struct DriverManager {
  private static let installedDriverURL = URL(
    fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/SpeakerRouterHAL.driver",
    isDirectory: true
  )

  func currentState() -> DriverInstallationState {
    guard let bundledDriverURL, let bundledVersion = version(of: bundledDriverURL) else {
      return .bundledDriverMissing
    }
    guard FileManager.default.fileExists(atPath: Self.installedDriverURL.path) else {
      return .notInstalled(bundledVersion: bundledVersion)
    }
    guard let installedVersion = version(of: Self.installedDriverURL) else {
      return .updateAvailable(installedVersion: "未知", bundledVersion: bundledVersion)
    }
    if installedVersion == bundledVersion {
      return .installed(version: installedVersion)
    }
    return .updateAvailable(
      installedVersion: installedVersion,
      bundledVersion: bundledVersion
    )
  }

  func perform(
    _ action: DriverManagerAction,
    onAuthorized: @escaping @MainActor () -> Void
  ) async throws {
    guard let resourcesURL = Bundle.main.resourceURL else {
      throw DriverManagerError("找不到 App 资源目录")
    }
    let helperURL = resourcesURL.appendingPathComponent("driver-manager.sh")
    guard FileManager.default.fileExists(atPath: helperURL.path) else {
      throw DriverManagerError("App 内缺少驱动管理脚本")
    }

    var sourcePath = ""
    if action == .install {
      guard let bundledDriverURL else {
        throw DriverManagerError("App 内缺少 SpeakerRouterHAL.driver")
      }
      sourcePath = bundledDriverURL.path
    }

    let coordinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakerRouter-driver-\(UUID().uuidString)", isDirectory: true)
    let readyURL = coordinationURL.appendingPathComponent("ready")
    let acknowledgementURL = coordinationURL.appendingPathComponent("acknowledged")
    try FileManager.default.createDirectory(
      at: coordinationURL,
      withIntermediateDirectories: false
    )
    try Data("waiting".utf8).write(to: readyURL)
    defer {
      try? FileManager.default.removeItem(at: coordinationURL)
    }

    try await Self.runAuthorizedHelper(
      helperPath: helperURL.path,
      action: action.rawValue,
      sourcePath: sourcePath,
      readyPath: readyURL.path,
      acknowledgementPath: acknowledgementURL.path,
      onAuthorized: onAuthorized
    )
  }

  private var bundledDriverURL: URL? {
    guard let url = Bundle.main.resourceURL?
      .appendingPathComponent("SpeakerRouterHAL.driver", isDirectory: true),
      FileManager.default.fileExists(atPath: url.path)
    else {
      return nil
    }
    return url
  }

  private func version(of bundleURL: URL) -> String? {
    let infoURL = bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      return nil
    }
    return info["CFBundleShortVersionString"] as? String
  }

  private static func runAuthorizedHelper(
    helperPath: String,
    action: String,
    sourcePath: String,
    readyPath: String,
    acknowledgementPath: String,
    onAuthorized: @escaping @MainActor () -> Void
  ) async throws {
    let authorizationScript = """
      on run argv
        set helperPath to item 1 of argv
        set actionName to item 2 of argv
        set sourcePath to item 3 of argv
        set readyPath to item 4 of argv
        set acknowledgementPath to item 5 of argv
        do shell script "/bin/zsh " & quoted form of helperPath & " " & quoted form of actionName & " " & quoted form of sourcePath & " " & quoted form of readyPath & " " & quoted form of acknowledgementPath with administrator privileges
      end run
      """
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [
      "-e", authorizationScript, "--", helperPath, action, sourcePath,
      readyPath, acknowledgementPath,
    ]
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()

    var acknowledged = false
    while process.isRunning {
      if !acknowledged,
        let marker = try? String(contentsOfFile: readyPath, encoding: .utf8),
        marker.trimmingCharacters(in: .whitespacesAndNewlines) == "authorized"
      {
        await onAuthorized()
        try Data().write(to: URL(fileURLWithPath: acknowledgementPath))
        acknowledged = true
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    process.waitUntilExit()

    let errorOutput = String(
      data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    guard process.terminationStatus == 0 else {
      let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      if message.localizedCaseInsensitiveContains("user canceled")
        || message.contains("(-128)")
      {
        throw DriverManagerError.cancelled
      }
      throw DriverManagerError.message(message.isEmpty ? "驱动操作失败" : message)
    }
  }
}

enum DriverManagerError: LocalizedError {
  case cancelled
  case message(String)

  init(_ message: String) {
    self = .message(message)
  }

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return "已取消驱动操作"
    case .message(let message):
      return message
    }
  }

  var isCancellation: Bool {
    if case .cancelled = self {
      return true
    }
    return false
  }
}
