import Darwin
import Foundation
import SpeakerRouterCore

@MainActor
final class GuardCoordinator: NSObject {
  private let heartbeatURL: URL
  private var fallbackDeviceUID: String?
  private var process: Process?
  private var timer: Timer?

  override init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    heartbeatURL =
      appSupport
      .appendingPathComponent("SpeakerRouter", isDirectory: true)
      .appendingPathComponent("guard-heartbeat.json")
    super.init()
  }

  @discardableResult
  func startOrUpdate(fallbackDeviceUID: String) throws -> Bool {
    self.fallbackDeviceUID = fallbackDeviceUID
    try writeHeartbeat(cleanShutdown: false)

    if process?.isRunning == true {
      return true
    }

    let helperURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Helpers", isDirectory: true)
      .appendingPathComponent("SpeakerRouterGuard")
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      return false
    }

    let process = Process()
    process.executableURL = helperURL
    process.arguments = [
      "--parent-pid", String(getpid()),
      "--heartbeat", heartbeatURL.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    self.process = process

    timer?.invalidate()
    timer = Timer.scheduledTimer(
      timeInterval: 1,
      target: self,
      selector: #selector(heartbeatTimerFired),
      userInfo: nil,
      repeats: true
    )
    return true
  }

  func stopCleanly() {
    timer?.invalidate()
    timer = nil
    try? writeHeartbeat(cleanShutdown: true)
    if process?.isRunning == true {
      process?.terminate()
    }
    process = nil
    fallbackDeviceUID = nil
  }

  @objc private func heartbeatTimerFired() {
    try? writeHeartbeat(cleanShutdown: false)
  }

  private func writeHeartbeat(cleanShutdown: Bool) throws {
    guard let fallbackDeviceUID else { return }
    let state = GuardHeartbeat(
      parentProcessID: getpid(),
      fallbackDeviceUID: fallbackDeviceUID,
      cleanShutdown: cleanShutdown
    )
    let directory = heartbeatURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(state).write(to: heartbeatURL, options: .atomic)
  }
}
