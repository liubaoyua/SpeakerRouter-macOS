import AppKit
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
  @Published var lastError: String?

  private let repository = CoreAudioDeviceRepository()
  private let watcher = CoreAudioDeviceWatcher()
  private let systemController = CoreAudioSystemController()
  private let volumeWatcher = CoreAudioVolumeWatcher()
  private let guardCoordinator = GuardCoordinator()
  private let relayEngine: AudioRelayEngine?
  private let store: FileRoutingStateStore
  private let diagnosticsURL: URL?
  private var diagnosticsTimer: Timer?
  private var liveDevices: [OutputDevice] = []
  private var state: RoutingState
  private var virtualDeviceID: AudioObjectID?
  private var activePhysicalDeviceUID: String?

  init() {
    diagnosticsURL = Self.commandLineArgument(after: "--diagnostics-file")
      .map { URL(fileURLWithPath: $0) }
    relayEngine = try? AudioRelayEngine()
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    store = FileRoutingStateStore(
      fileURL:
        appSupport
        .appendingPathComponent("SpeakerRouter", isDirectory: true)
        .appendingPathComponent("routing-state.json")
    )
    state = (try? store.load()) ?? RoutingState()
    Self.shared = self
    configureLaunchAtLogin()
    refresh()
    do {
      try watcher.start { [weak self] result in
        Task { @MainActor in
          self?.applyDeviceSnapshot(result)
        }
      }
    } catch {
      lastError = String(describing: error)
    }
    if diagnosticsURL != nil {
      diagnosticsTimer = Timer.scheduledTimer(
        timeInterval: 0.5,
        target: self,
        selector: #selector(diagnosticsTimerFired),
        userInfo: nil,
        repeats: true
      )
    }
  }

  func refresh() {
    do {
      applyDeviceSnapshot(.success(try repository.outputDevices()))
    } catch {
      lastError = String(describing: error)
    }
  }

  func select(_ uid: String) {
    state.selectManually(uid: uid, discovered: liveDevices)
    persistAndPublish()
    reconcileAudioRoute()
  }

  func useAutomaticRouting() {
    state.returnToAutomaticRouting()
    persistAndPublish()
    reconcileAudioRoute()
  }

  func move(_ uid: String, offset: Int) {
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
      reconcileAudioRoute()
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
    guard let relayEngine else {
      routeStatus = "实时音频引擎初始化失败"
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
        try relayEngine.start(
          sourceDeviceID: virtualID,
          destinationDeviceID: destination.objectID,
          gain: VolumeCurve.gain(for: volumeScalar)
        )
        try systemController.setOutputVolume(Float(volumeScalar), of: virtualID)
        try systemController.setOutputMute(false, of: virtualID)
        try systemController.setDefaultOutputs(to: virtualID)
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

  private var isInstalledInApplications: Bool {
    let path = Bundle.main.bundleURL.standardizedFileURL.path
    return path.hasPrefix("/Applications/")
  }

  @objc private func diagnosticsTimerFired() {
    writeRelayDiagnostics()
  }

  private func writeRelayDiagnostics() {
    guard let diagnosticsURL, let relayEngine else { return }
    let snapshot = RelayDiagnosticsSnapshot(
      schemaVersion: 1,
      updatedAt: Date(),
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
      // Test-only diagnostics must never disrupt routing.
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
  let selectedDeviceUID: String?
  let selectedDeviceName: String?
  let routeStatus: String
  let statistics: AudioRelayStatistics
}

struct RouterMenuView: View {
  @ObservedObject var model: RouterViewModel

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
