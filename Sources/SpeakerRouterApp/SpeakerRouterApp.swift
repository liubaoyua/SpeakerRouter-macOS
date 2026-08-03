import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import SpeakerRouterCore
import SwiftUI

@main
struct SpeakerRouterApp: App {
  @NSApplicationDelegateAdaptor(RouterApplicationDelegate.self) private var appDelegate
  @StateObject private var model = RouterViewModel()

  var body: some Scene {
    MenuBarExtra {
      RouterMenuView(model: model)
    } label: {
      Label("SpeakerRouter", systemImage: "speaker.wave.2.fill")
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
final class RouterApplicationDelegate: NSObject, NSApplicationDelegate {
  private var debugWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard CommandLine.arguments.contains("--show-window") else {
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let model = RouterViewModel.shared else { return }
      self?.showDebugWindow(model: model)
    }
  }

  private func showDebugWindow(model: RouterViewModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "SpeakerRouter"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: RouterMenuView(model: model))
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    debugWindow = window
  }

  func applicationWillTerminate(_ notification: Notification) {
    RouterViewModel.shared?.shutdown()
  }
}

@MainActor
final class RouterViewModel: ObservableObject {
  static weak var shared: RouterViewModel?

  @Published private(set) var devices: [RoutableOutputDevice] = []
  @Published private(set) var selectedUID: String?
  @Published private(set) var manualLockedUID: String?
  @Published private(set) var routeStatus = "正在检查音频设备…"
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var driverState: DriverInstallationState = .checking
  @Published private(set) var microphoneAccessDenied = false
  @Published var lastError: String?

  private let repository = CoreAudioDeviceRepository()
  private let watcher = CoreAudioDeviceWatcher()
  private let systemController = CoreAudioSystemController()
  private let volumeWatcher = CoreAudioVolumeWatcher()
  private let guardCoordinator = GuardCoordinator()
  private let driverManager = DriverManager()
  private let relayEngine: AudioRelayEngine?
  private let store: FileRoutingStateStore
  private let diagnosticsURL: URL?
  private var diagnosticsTimer: Timer?
  private var relayHealthTimer: Timer?
  private var previousRelayStatistics: AudioRelayStatistics?
  private var stalledRelayHealthChecks = 0
  private var routeRecoveryInProgress = false
  private var audioInputAuthorization = AudioInputAuthorization.checking
  private var liveDevices: [OutputDevice] = []
  private var state: RoutingState
  private var virtualDeviceID: AudioObjectID?
  private var activePhysicalDeviceUID: String?

  init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    diagnosticsURL = Self.commandLineArgument(after: "--diagnostics-file")
      .map { URL(fileURLWithPath: $0) }
      ?? appSupport
        .appendingPathComponent("SpeakerRouter", isDirectory: true)
        .appendingPathComponent("live-diagnostics.json")
    relayEngine = try? AudioRelayEngine()
    store = FileRoutingStateStore(
      fileURL:
        appSupport
        .appendingPathComponent("SpeakerRouter", isDirectory: true)
        .appendingPathComponent("routing-state.json")
    )
    state = (try? store.load()) ?? RoutingState()
    Self.shared = self
    refreshDriverState()
    configureLaunchAtLogin()
    configureAudioInputAuthorization()
    refresh()
    startDeviceWatcher()
    relayHealthTimer = Timer.scheduledTimer(
      timeInterval: 1,
      target: self,
      selector: #selector(relayHealthTimerFired),
      userInfo: nil,
      repeats: true
    )
    diagnosticsTimer = Timer.scheduledTimer(
      timeInterval: 0.5,
      target: self,
      selector: #selector(diagnosticsTimerFired),
      userInfo: nil,
      repeats: true
    )
  }

  func refresh() {
    do {
      applyDeviceSnapshot(.success(try repository.outputDevices()))
    } catch {
      lastError = String(describing: error)
    }
  }

  func select(_ uid: String) {
    resetRelayHealthTracking()
    state.selectManually(uid: uid, discovered: liveDevices)
    persistAndPublish()
    reconcileAudioRoute()
  }

  func useAutomaticRouting() {
    resetRelayHealthTracking()
    state.returnToAutomaticRouting()
    persistAndPublish()
    reconcileAudioRoute()
  }

  func move(_ uid: String, offset: Int) {
    resetRelayHealthTracking()
    guard let current = state.preferences.firstIndex(where: { $0.uid == uid }) else {
      return
    }
    state.moveDevice(uid: uid, to: current + offset)
    persistAndPublish()
    reconcileAudioRoute()
  }

  func setVolume(_ volume: Double, for uid: String) {
    state.setVolume(volume, for: uid)
    persistAndPublish()
    guard uid == selectedUID else { return }
    let scalar = Float(min(max(volume, 0), 1))
    relayEngine?.setGain(VolumeCurve.gain(for: volume))
    if let virtualDeviceID {
      do {
        try systemController.setOutputVolume(scalar, of: virtualDeviceID)
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func shutdown() {
    diagnosticsTimer?.invalidate()
    diagnosticsTimer = nil
    relayHealthTimer?.invalidate()
    relayHealthTimer = nil
    resetRelayHealthTracking()
    writeRelayDiagnostics()
    guardCoordinator.stopCleanly()
    volumeWatcher.stop()
    relayEngine?.stop()
    if let activePhysicalDeviceUID,
      let device = liveDevices.first(where: { $0.uid == activePhysicalDeviceUID })
    {
      try? systemController.setDefaultOutputs(to: device.objectID)
    }
    virtualDeviceID = nil
    routeStatus = "已停止，并恢复物理输出"
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    guard isInstalledInApplications else {
      launchAtLoginEnabled = false
      lastError = "请先将 SpeakerRouter.app 移到“应用程序”文件夹，再启用登录时启动"
      return
    }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      lastError = nil
    } catch {
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      lastError = String(describing: error)
    }
  }

  func openMicrophonePrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  func installOrUpdateDriver() {
    changeDriver(.install)
  }

  func uninstallDriver() {
    changeDriver(.uninstall)
  }

  private func persistAndPublish() {
    updatePublishedState()
    do {
      try store.save(state)
      lastError = nil
    } catch {
      lastError = String(describing: error)
    }
  }

  private func applyDeviceSnapshot(_ result: Result<[OutputDevice], Error>) {
    do {
      liveDevices = try result.get()
      state.reconcile(with: liveDevices)
      updatePublishedState()
      try store.save(state)
      lastError = nil
      if !driverState.isChanging {
        reconcileAudioRoute()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  private func updatePublishedState() {
    devices = state.rows(with: liveDevices)
    selectedUID = state.selectedDeviceUID(from: liveDevices)
    manualLockedUID = state.manualLockedDeviceUID
  }

  private func reconcileAudioRoute() {
    guard !driverState.isChanging else { return }
    guard let relayEngine else {
      routeStatus = "实时音频引擎初始化失败"
      return
    }
    guard audioInputAuthorization == .authorized else {
      volumeWatcher.stop()
      guardCoordinator.stopCleanly()
      relayEngine.stop()
      restoreFallbackPhysicalOutput()
      virtualDeviceID = nil
      activePhysicalDeviceUID = nil
      resetRelayHealthTracking()
      routeStatus = audioInputAuthorization.routeStatus
      return
    }

    do {
      guard
        let virtualID = try systemController.deviceID(
          forUID: CoreAudioSystemController.speakerRouterDeviceUID
        )
      else {
        volumeWatcher.stop()
        guardCoordinator.stopCleanly()
        relayEngine.stop()
        virtualDeviceID = nil
        activePhysicalDeviceUID = nil
        resetRelayHealthTracking()
        routeStatus = "虚拟音频驱动尚未安装"
        return
      }
      guard let selectedUID,
        let destination = liveDevices.first(where: { $0.uid == selectedUID })
      else {
        volumeWatcher.stop()
        guardCoordinator.stopCleanly()
        relayEngine.stop()
        restoreFallbackPhysicalOutput()
        activePhysicalDeviceUID = nil
        resetRelayHealthTracking()
        routeStatus = "没有可用的物理输出"
        return
      }

      if activePhysicalDeviceUID != selectedUID || !relayEngine.isRunning {
        let previousDefault = try systemController.defaultOutputDeviceID()
        if previousDefault != virtualID,
          let previousUID = systemController.deviceUID(for: previousDefault),
          let previousDevice = liveDevices.first(where: { $0.hardwareUID == previousUID })
        {
          state.lastUsablePhysicalDeviceUID = previousDevice.uid
        }

        let volumeScalar = state.volume(for: selectedUID)
        try systemController.setOutputVolume(Float(volumeScalar), of: virtualID)
        try systemController.setOutputMute(false, of: virtualID)
        try systemController.setDefaultOutputs(to: virtualID)
        try relayEngine.start(
          sourceDeviceID: virtualID,
          destinationDeviceID: destination.objectID,
          gain: VolumeCurve.gain(for: volumeScalar)
        )
        resetRelayHealthTracking(baseline: relayEngine.statistics())
        state.lastUsablePhysicalDeviceUID = selectedUID
        activePhysicalDeviceUID = selectedUID
        virtualDeviceID = virtualID
        try store.save(state)

        try volumeWatcher.start(deviceID: virtualID) { [weak self] level in
          Task { @MainActor in
            self?.virtualOutputLevelChanged(level)
          }
        }
        let guardRunning = try guardCoordinator.startOrUpdate(
          fallbackDeviceUID: destination.hardwareUID
        )
        if !guardRunning {
          routeStatus = "正在输出到 \(destination.name)（开发模式未启用守护）"
          return
        }
      }
      routeStatus = "正在输出到 \(destination.name)"
    } catch {
      guardCoordinator.stopCleanly()
      volumeWatcher.stop()
      relayEngine.stop()
      restoreFallbackPhysicalOutput()
      virtualDeviceID = nil
      activePhysicalDeviceUID = nil
      resetRelayHealthTracking()
      routeStatus = "音频路由启动失败"
      lastError = String(describing: error)
    }
  }

  private func virtualOutputLevelChanged(_ level: OutputLevel) {
    let effectiveGain: Float =
      level.isMuted
      ? 0
      : VolumeCurve.gain(for: Double(level.volume))
    relayEngine?.setGain(effectiveGain)
    guard let selectedUID else { return }
    state.setVolume(Double(level.volume), for: selectedUID)
    persistAndPublish()
  }

  private func restoreFallbackPhysicalOutput() {
    let preferredUID =
      activePhysicalDeviceUID
      ?? state.lastUsablePhysicalDeviceUID
      ?? selectedUID
    guard let preferredUID,
      let fallback = liveDevices.first(where: { $0.uid == preferredUID })
    else {
      return
    }
    try? systemController.setDefaultOutputs(to: fallback.objectID)
  }

  private func configureLaunchAtLogin() {
    guard isInstalledInApplications else {
      if SMAppService.mainApp.status == .enabled {
        try? SMAppService.mainApp.unregister()
      }
      launchAtLoginEnabled = false
      return
    }
    do {
      if SMAppService.mainApp.status != .enabled {
        try SMAppService.mainApp.register()
      }
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    } catch {
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      lastError = String(describing: error)
    }
  }

  private func configureAudioInputAuthorization() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      audioInputAuthorization = .authorized
      microphoneAccessDenied = false
    case .notDetermined:
      audioInputAuthorization = .requesting
      microphoneAccessDenied = false
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        Task { @MainActor in
          guard let self else { return }
          self.audioInputAuthorization = granted ? .authorized : .denied
          self.microphoneAccessDenied = !granted
          self.resetRelayHealthTracking()
          self.refresh()
        }
      }
    case .denied, .restricted:
      audioInputAuthorization = .denied
      microphoneAccessDenied = true
    @unknown default:
      audioInputAuthorization = .denied
      microphoneAccessDenied = true
    }
  }

  private func refreshDriverState() {
    driverState = driverManager.currentState()
  }

  private func changeDriver(_ action: DriverManagerAction) {
    guard !driverState.isChanging else { return }
    driverState = .changing(
      message: action == .install ? "等待管理员授权…" : "等待卸载授权…"
    )

    Task {
      var routingWasSuspended = false
      do {
        try await driverManager.perform(action) {
          routingWasSuspended = true
          self.suspendRoutingForDriverChange()
          self.driverState = .changing(message: "正在更新音频驱动…")
        }
        driverState = .changing(message: "正在等待音频服务恢复…")
        routeRecoveryInProgress = true
        try await recoverAfterDriverChange(action)
        routeRecoveryInProgress = false
        lastError = nil
      } catch {
        routeRecoveryInProgress = false
        refreshDriverState()
        if routingWasSuspended {
          startDeviceWatcher()
          refresh()
        }
        if let driverError = error as? DriverManagerError,
          driverError.isCancellation
        {
          lastError = nil
        } else {
          lastError = error.localizedDescription
        }
      }
    }
  }

  private func suspendRoutingForDriverChange() {
    watcher.stop()
    guardCoordinator.stopCleanly()
    volumeWatcher.stop()
    relayEngine?.stop()
    restoreFallbackPhysicalOutput()
    virtualDeviceID = nil
    activePhysicalDeviceUID = nil
    resetRelayHealthTracking()
    routeStatus = "已暂停路由，等待驱动操作"
  }

  private func recoverAfterDriverChange(_ action: DriverManagerAction) async throws {
    let expectsInstalledDriver = action == .install
    var lastRecoveryError: Error?
    let recoveryDeadline = Date().addingTimeInterval(10)

    while Date() < recoveryDeadline {
      do {
        let virtualID = try systemController.deviceID(
          forUID: CoreAudioSystemController.speakerRouterDeviceUID
        )
        let driverIsReady = expectsInstalledDriver ? virtualID != nil : virtualID == nil
        guard driverIsReady else {
          try await Task.sleep(for: .milliseconds(250))
          continue
        }

        let snapshot = try repository.outputDevices()
        refreshDriverState()
        startDeviceWatcher()
        applyDeviceSnapshot(.success(snapshot))

        if !expectsInstalledDriver {
          return
        }
        if let relayEngine, relayEngine.isRunning,
          let virtualDeviceID,
          try systemController.defaultOutputDeviceID() == virtualDeviceID
        {
          let baseline = relayEngine.statistics()
          try await Task.sleep(for: .milliseconds(750))
          let current = relayEngine.statistics()
          if current.callbacksAdvanced(since: baseline) {
            resetRelayHealthTracking(baseline: current)
            return
          }
          lastRecoveryError = RelayCallbacksStalledError()
          tearDownStalledRelay()
        }
      } catch {
        lastRecoveryError = error
      }
      try await Task.sleep(for: .milliseconds(250))
    }

    refreshDriverState()
    startDeviceWatcher()
    refresh()
    throw DriverRecoveryError(
      underlyingDescription: lastRecoveryError.map(String.init(describing:))
    )
  }

  private func startDeviceWatcher() {
    do {
      try watcher.start { [weak self] result in
        Task { @MainActor in
          self?.applyDeviceSnapshot(result)
        }
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  private var isInstalledInApplications: Bool {
    let path = Bundle.main.bundleURL.standardizedFileURL.path
    return path.hasPrefix("/Applications/")
  }

  @objc private func relayHealthTimerFired() {
    guard !driverState.isChanging, !routeRecoveryInProgress,
      let relayEngine, relayEngine.isRunning
    else {
      if relayEngine?.isRunning != true {
        resetRelayHealthTracking()
      }
      return
    }

    let current = relayEngine.statistics()
    guard let previousRelayStatistics else {
      resetRelayHealthTracking(baseline: current)
      return
    }

    if current.callbacksAdvanced(since: previousRelayStatistics) {
      self.previousRelayStatistics = current
      stalledRelayHealthChecks = 0
      return
    }

    self.previousRelayStatistics = current
    stalledRelayHealthChecks += 1
    guard stalledRelayHealthChecks >= 2 else { return }

    routeRecoveryInProgress = true
    routeStatus = "检测到音频转发停滞，正在自动恢复…"
    tearDownStalledRelay()
    refresh()
    routeRecoveryInProgress = false
  }

  private func tearDownStalledRelay() {
    guardCoordinator.stopCleanly()
    volumeWatcher.stop()
    relayEngine?.stop()
    restoreFallbackPhysicalOutput()
    virtualDeviceID = nil
    activePhysicalDeviceUID = nil
    resetRelayHealthTracking()
  }

  private func resetRelayHealthTracking(baseline: AudioRelayStatistics? = nil) {
    previousRelayStatistics = baseline
    stalledRelayHealthChecks = 0
  }

  @objc private func diagnosticsTimerFired() {
    writeRelayDiagnostics()
  }

  private func writeRelayDiagnostics() {
    guard let diagnosticsURL, let relayEngine else { return }
    let snapshot = RelayDiagnosticsSnapshot(
      schemaVersion: 4,
      updatedAt: Date(),
      processID: ProcessInfo.processInfo.processIdentifier,
      appVersion: Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "未知",
      audioInputAuthorization: audioInputAuthorization.diagnosticsDescription,
      driverStatus: driverState.description,
      selectedDeviceUID: selectedUID,
      selectedDeviceName: devices.first(where: { $0.id == selectedUID })?.displayName,
      routeStatus: routeStatus,
      statistics: relayEngine.statistics()
    )
    do {
      let directory = diagnosticsURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try JSONEncoder().encode(snapshot).write(to: diagnosticsURL, options: .atomic)
    } catch {
      // Diagnostics must never disrupt routing.
    }
  }

  private static func commandLineArgument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
      CommandLine.arguments.indices.contains(index + 1)
    else {
      return nil
    }
    return CommandLine.arguments[index + 1]
  }
}

private struct RelayDiagnosticsSnapshot: Codable {
  let schemaVersion: Int
  let updatedAt: Date
  let processID: Int32
  let appVersion: String
  let audioInputAuthorization: String
  let driverStatus: String
  let selectedDeviceUID: String?
  let selectedDeviceName: String?
  let routeStatus: String
  let statistics: AudioRelayStatistics
}

private enum AudioInputAuthorization: Equatable {
  case checking
  case requesting
  case authorized
  case denied

  var routeStatus: String {
    switch self {
    case .checking:
      return "正在检查音频输入权限…"
    case .requesting:
      return "等待允许麦克风权限（用于读取虚拟音频）"
    case .authorized:
      return "音频输入权限已允许"
    case .denied:
      return "麦克风权限未允许，无法读取虚拟音频"
    }
  }

  var diagnosticsDescription: String {
    switch self {
    case .checking:
      return "checking"
    case .requesting:
      return "requesting"
    case .authorized:
      return "authorized"
    case .denied:
      return "denied"
    }
  }
}

private struct DriverRecoveryError: LocalizedError {
  let underlyingDescription: String?

  var errorDescription: String? {
    if let underlyingDescription {
      return "驱动已变更，但音频路由未能自动恢复：\(underlyingDescription)"
    }
    return "驱动已变更，但音频路由未能在 10 秒内自动恢复"
  }
}

private struct RelayCallbacksStalledError: LocalizedError {
  var errorDescription: String? {
    "音频回调没有产生新的捕获帧和渲染帧"
  }
}

struct RouterMenuView: View {
  @ObservedObject var model: RouterViewModel
  @State private var confirmingDriverUninstall = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("输出设备")
          .font(.headline)
        Spacer()
        Button {
          model.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help("重新扫描设备")
      }

      Text(model.routeStatus)
        .font(.caption)
        .foregroundStyle(.secondary)

      if model.microphoneAccessDenied {
        HStack {
          Text("需要在“隐私与安全性 → 麦克风”中允许 SpeakerRouter")
            .font(.caption)
            .foregroundStyle(.orange)
          Spacer()
          Button("打开系统设置") {
            model.openMicrophonePrivacySettings()
          }
        }
      }

      if model.devices.isEmpty {
        ContentUnavailableView(
          "没有可用的物理输出",
          systemImage: "speaker.slash"
        )
      } else {
        ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, row in
          deviceRow(row, index: index)
        }
      }

      Divider()

      Toggle(
        "登录时自动启动",
        isOn: Binding(
          get: { model.launchAtLoginEnabled },
          set: { model.setLaunchAtLogin($0) }
        )
      )

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("音频驱动")
            .font(.headline)
          Spacer()
          Text(model.driverState.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          if let title = model.driverState.primaryActionTitle {
            Button(title) {
              model.installOrUpdateDriver()
            }
          }

          if model.driverState.canUninstall {
            if confirmingDriverUninstall {
              Text("确认卸载？")
                .font(.caption)
                .foregroundStyle(.secondary)
              Button("确认", role: .destructive) {
                confirmingDriverUninstall = false
                model.uninstallDriver()
              }
              Button("取消") {
                confirmingDriverUninstall = false
              }
            } else {
              Button("卸载驱动", role: .destructive) {
                confirmingDriverUninstall = true
              }
            }
          }

          if model.driverState.isChanging {
            ProgressView()
              .controlSize(.small)
          }
        }
      }

      HStack {
        Button("自动选择") {
          model.useAutomaticRouting()
        }
        .disabled(model.manualLockedUID == nil)

        Spacer()

        Button("退出") {
          NSApplication.shared.terminate(nil)
        }
      }

      if let error = model.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .padding(14)
    .frame(width: 420)
  }

  @ViewBuilder
  private func deviceRow(_ row: RoutableOutputDevice, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Circle()
          .fill(row.isOnline ? Color.green : Color.secondary.opacity(0.35))
          .frame(width: 8, height: 8)

        Button {
          model.select(row.id)
        } label: {
          HStack {
            Text(row.displayName)
            if model.selectedUID == row.id {
              Image(systemName: model.manualLockedUID == row.id ? "lock.fill" : "checkmark")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!row.isOnline)

        Button {
          model.move(row.id, offset: -1)
        } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.plain)
        .disabled(index == 0)

        Button {
          model.move(row.id, offset: 1)
        } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.plain)
        .disabled(index == model.devices.count - 1)
      }

      HStack {
        Image(systemName: "speaker.fill")
          .foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { row.preference.volume },
            set: { model.setVolume($0, for: row.id) }
          ),
          in: 0...1
        )
        Text("\(Int((row.preference.volume * 100).rounded()))%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
    }
    .opacity(row.isOnline ? 1 : 0.55)
  }
}
