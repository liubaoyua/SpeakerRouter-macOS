import AppKit
import CoreAudio
import ServiceManagement
import SpeakerRouterCore
import SwiftUI

@main
struct SpeakerRouterApp: App {
  @NSApplicationDelegateAdaptor(RouterApplicationDelegate.self) private var appDelegate
  @StateObject private var model = RouterViewModel()

  private static let menuBarIcon: NSImage = {
    let image = NSImage(size: NSSize(width: 22, height: 16), flipped: true) { _ in
      NSColor.black.setFill()
      NSColor.black.setStroke()

      NSBezierPath(
        roundedRect: NSRect(x: 0.5, y: 6, width: 3.7, height: 4),
        xRadius: 1,
        yRadius: 1
      ).fill()

      let cone = NSBezierPath()
      cone.move(to: NSPoint(x: 3.8, y: 6))
      cone.line(to: NSPoint(x: 8, y: 2.5))
      cone.line(to: NSPoint(x: 8, y: 13.5))
      cone.line(to: NSPoint(x: 3.8, y: 10))
      cone.close()
      cone.fill()

      let route = NSBezierPath()
      route.move(to: NSPoint(x: 10.5, y: 3))
      route.line(to: NSPoint(x: 13, y: 3))
      route.curve(
        to: NSPoint(x: 18.3, y: 8),
        controlPoint1: NSPoint(x: 15.1, y: 3),
        controlPoint2: NSPoint(x: 15.8, y: 6.2)
      )
      route.move(to: NSPoint(x: 10.5, y: 13))
      route.line(to: NSPoint(x: 13, y: 13))
      route.curve(
        to: NSPoint(x: 18.3, y: 8),
        controlPoint1: NSPoint(x: 15.1, y: 13),
        controlPoint2: NSPoint(x: 15.8, y: 9.8)
      )
      route.line(to: NSPoint(x: 19.5, y: 8))
      route.lineWidth = 2.2
      route.lineCapStyle = .round
      route.lineJoinStyle = .round
      route.stroke()

      NSBezierPath(ovalIn: NSRect(x: 18.5, y: 6.3, width: 3.4, height: 3.4)).fill()
      return true
    }
    image.isTemplate = true
    return image
  }()

  var body: some Scene {
    MenuBarExtra {
      RouterMenuView(model: model)
    } label: {
      Label {
        Text("SpeakerRouter")
      } icon: {
        Image(nsImage: Self.menuBarIcon)
      }
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
final class RouterApplicationDelegate: NSObject, NSApplicationDelegate {
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
  @Published var lastError: String?

  private let repository = CoreAudioDeviceRepository()
  private let watcher = CoreAudioDeviceWatcher()
  private let systemController = CoreAudioSystemController()
  private let volumeWatcher = CoreAudioVolumeWatcher()
  private let guardCoordinator = GuardCoordinator()
  private let mediaPauseController = MediaPauseController()
  private lazy var mediaRemoteAdapter = MediaRemoteAdapterController { [weak self] playing in
    self?.mediaRemotePlayingChanged(playing)
  }
  private lazy var airPodsWearMonitor = AirPodsWearMonitor { [weak self] wearState in
    self?.airPodsWearStateChanged(wearState)
  }
  private let driverManager = DriverManager()
  private let relayEngine: AudioRelayEngine?
  private let store: FileRoutingStateStore
  private var relayHealthTimer: Timer?
  private var previousRelayStatistics: AudioRelayStatistics?
  private var stalledRelayHealthChecks = 0
  private var routeRecoveryInProgress = false
  private var failedRouteAttempt: String?
  private var liveDevices: [OutputDevice] = []
  private var state: RoutingState
  private var airPodsWearBehavior = AirPodsWearPlaybackBehavior()
  private var recentAudioActivity = RecentAudioActivityTracker()
  private var airPodsPauseRetryTask: Task<Void, Never>?
  private var lastAdapterPauseReassertion: TimeInterval?
  private var virtualDeviceID: AudioObjectID?
  private var activePhysicalDeviceUID: String?

  init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    relayEngine = try? AudioRelayEngine()
    store = FileRoutingStateStore(
      fileURL:
        appSupport
        .appendingPathComponent("SpeakerRouter", isDirectory: true)
        .appendingPathComponent("routing-state.json")
    )
    state = (try? store.load()) ?? RoutingState()
    Self.shared = self
    mediaRemoteAdapter.start()
    refreshDriverState()
    configureLaunchAtLogin()
    refresh()
    startDeviceWatcher()
    relayHealthTimer = Timer.scheduledTimer(
      timeInterval: 1,
      target: self,
      selector: #selector(relayHealthTimerFired),
      userInfo: nil,
      repeats: true
    )
  }

  func refresh() {
    let repository = repository
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Result { try repository.outputDevices() }
      }.value
      self?.applyDeviceSnapshot(result)
    }
  }

  func select(_ uid: String) {
    failedRouteAttempt = nil
    resetRelayHealthTracking()
    state.selectManually(uid: uid, discovered: liveDevices)
    persistAndPublish()
    reconcileAudioRoute()
  }

  func useAutomaticRouting() {
    failedRouteAttempt = nil
    resetRelayHealthTracking()
    state.returnToAutomaticRouting()
    persistAndPublish()
    reconcileAudioRoute()
  }

  func move(_ uid: String, offset: Int) {
    failedRouteAttempt = nil
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
    relayHealthTimer?.invalidate()
    relayHealthTimer = nil
    resetRelayHealthTracking()
    stopAirPodsWearMonitoring()
    mediaRemoteAdapter.stop()
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
      let snapshot = try result.get()
      if relayEngine?.isRunning == true,
        DeviceDisconnectBehavior.shouldPauseMedia(
          activeDeviceUID: activePhysicalDeviceUID,
          previousDevices: liveDevices,
          currentDevices: snapshot
        )
      {
        sendMediaPause()
      }
      if snapshot.map(\.uid) != liveDevices.map(\.uid) {
        failedRouteAttempt = nil
      }
      liveDevices = snapshot
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
    guard driverState.isCompatibleForRouting else {
      guardCoordinator.stopCleanly()
      volumeWatcher.stop()
      relayEngine.stop()
      restoreFallbackPhysicalOutput()
      stopAirPodsWearMonitoring()
      virtualDeviceID = nil
      activePhysicalDeviceUID = nil
      failedRouteAttempt = nil
      resetRelayHealthTracking()
      routeStatus = driverState.routingUnavailableMessage
      return
    }
    var routeAttempt: String?
    do {
      guard
        let virtualID = try systemController.deviceID(
          forUID: CoreAudioSystemController.speakerRouterDeviceUID
        )
      else {
        volumeWatcher.stop()
        guardCoordinator.stopCleanly()
        relayEngine.stop()
        stopAirPodsWearMonitoring()
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
        stopAirPodsWearMonitoring()
        activePhysicalDeviceUID = nil
        resetRelayHealthTracking()
        routeStatus = "没有可用的物理输出"
        return
      }

      routeAttempt = "\(virtualID):\(selectedUID)"
      guard failedRouteAttempt != routeAttempt else {
        routeStatus = "音频路由启动失败，等待设备变化或手动重试"
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
        try relayEngine.start(
            virtualDeviceID: virtualID,
          destinationDeviceID: destination.objectID,
          gain: VolumeCurve.gain(for: volumeScalar)
        )
        try systemController.setDefaultOutputs(to: virtualID)
        resetRelayHealthTracking(baseline: relayEngine.statistics())
        state.lastUsablePhysicalDeviceUID = selectedUID
        activePhysicalDeviceUID = selectedUID
        virtualDeviceID = virtualID
        startAirPodsWearMonitoring(for: destination)
        failedRouteAttempt = nil
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
      failedRouteAttempt = routeAttempt
      guardCoordinator.stopCleanly()
      volumeWatcher.stop()
      relayEngine.stop()
      restoreFallbackPhysicalOutput()
      stopAirPodsWearMonitoring()
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
    stopAirPodsWearMonitoring()
    virtualDeviceID = nil
    activePhysicalDeviceUID = nil
    failedRouteAttempt = nil
    resetRelayHealthTracking()
    routeStatus = "已暂停路由，等待驱动操作"
  }

  private func recoverAfterDriverChange(_ action: DriverManagerAction) async throws {
    let expectsInstalledDriver = action == .install
    let recoveryDeadline = Date().addingTimeInterval(10)
    var driverIsReady = false

    while Date() < recoveryDeadline {
      let virtualID = try systemController.deviceID(
        forUID: CoreAudioSystemController.speakerRouterDeviceUID
      )
      driverIsReady = expectsInstalledDriver ? virtualID != nil : virtualID == nil
      if driverIsReady {
        break
      }
      try await Task.sleep(for: .milliseconds(250))
    }

    guard driverIsReady else {
      throw DriverRecoveryError(underlyingDescription: "CoreAudio 未在 10 秒内刷新驱动状态")
    }

    let snapshot = try repository.outputDevices()
    refreshDriverState()
    startDeviceWatcher()
    applyDeviceSnapshot(.success(snapshot))

    guard expectsInstalledDriver else { return }
    guard let relayEngine, relayEngine.isRunning,
      let virtualDeviceID,
      try systemController.defaultOutputDeviceID() == virtualDeviceID
    else {
      throw DriverRecoveryError(underlyingDescription: lastError ?? "音频链路启动失败")
    }

    let baseline = relayEngine.statistics()
    try await Task.sleep(for: .milliseconds(750))
    let current = relayEngine.statistics()
    guard current.renderCallbackAdvanced(since: baseline) else {
      failedRouteAttempt = "\(virtualDeviceID):\(selectedUID ?? "")"
      tearDownStalledRelay()
      throw DriverRecoveryError(
        underlyingDescription: RelayRenderCallbackStalledError().localizedDescription
      )
    }
    resetRelayHealthTracking(baseline: current)
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
    recentAudioActivity.observe(
      writtenFrames: current.writtenFrames,
      at: Date.timeIntervalSinceReferenceDate
    )
    guard let previousRelayStatistics else {
      resetRelayHealthTracking(baseline: current)
      return
    }

    // No capture frames while the virtual output is silent is normal. The physical render
    // callback is the always-running liveness signal for the relay itself.
    if current.renderCallbackAdvanced(since: previousRelayStatistics) {
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
    failedRouteAttempt = nil
    refresh()
    routeRecoveryInProgress = false
  }

  private func tearDownStalledRelay() {
    guardCoordinator.stopCleanly()
    volumeWatcher.stop()
    relayEngine?.stop()
    restoreFallbackPhysicalOutput()
    stopAirPodsWearMonitoring()
    virtualDeviceID = nil
    activePhysicalDeviceUID = nil
    resetRelayHealthTracking()
  }

  private func resetRelayHealthTracking(baseline: AudioRelayStatistics? = nil) {
    previousRelayStatistics = baseline
    stalledRelayHealthChecks = 0
    recentAudioActivity.reset()
    if let baseline {
      recentAudioActivity.observe(
        writtenFrames: baseline.writtenFrames,
        at: Date.timeIntervalSinceReferenceDate
      )
    }
  }

  private func startAirPodsWearMonitoring(for device: OutputDevice) {
    cancelAirPodsPauseRetry()
    airPodsWearBehavior.reset()
    guard device.kind == .headphones,
      device.name.localizedCaseInsensitiveContains("airpods")
    else {
      airPodsWearMonitor.stop()
      return
    }
    airPodsWearMonitor.start(
      deviceName: device.name,
      hardwareUID: device.hardwareUID
    )
  }

  private func stopAirPodsWearMonitoring() {
    cancelAirPodsPauseRetry()
    airPodsWearBehavior.reset()
    airPodsWearMonitor.stop()
  }

  private func airPodsWearStateChanged(_ wearState: AirPodsWearState) {
    guard let relayEngine, relayEngine.isRunning,
      let activePhysicalDeviceUID,
      liveDevices.contains(where: {
        $0.uid == activePhysicalDeviceUID
          && $0.kind == .headphones
          && $0.name.localizedCaseInsensitiveContains("airpods")
      }),
      let action = airPodsWearBehavior.observe(wearState)
    else {
      return
    }

    switch action {
    case .requestPause:
      let now = Date.timeIntervalSinceReferenceDate
      let current = relayEngine.statistics()
      recentAudioActivity.observe(
        writtenFrames: current.writtenFrames,
        at: now
      )
      let fallbackHasRecentAudio = recentAudioActivity.hasRecentActivity(at: now)
      guard MediaPlaybackPauseDecision.shouldPause(
        adapterPlaying: mediaRemoteAdapter.isPlaying,
        fallbackHasRecentAudio: fallbackHasRecentAudio
      ), sendMediaPause()
      else {
        airPodsWearBehavior.cancelPauseRequest()
        return
      }
      airPodsWearBehavior.confirmPausedForRemoval()
      scheduleAirPodsPauseRetry()
    case .requestPlay:
      cancelAirPodsPauseRetry()
      if sendMediaPlay() {
        airPodsWearBehavior.confirmResumedAfterReinsertion()
      }
    }
  }

  private func scheduleAirPodsPauseRetry() {
    cancelAirPodsPauseRetry()
    airPodsPauseRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(750))
      guard !Task.isCancelled, let self,
        self.airPodsWearBehavior.shouldRemainPausedAfterRemoval,
        self.relayEngine?.isRunning == true
      else {
        return
      }
      self.sendMediaPause()
      self.airPodsPauseRetryTask = nil
    }
  }

  private func cancelAirPodsPauseRetry() {
    airPodsPauseRetryTask?.cancel()
    airPodsPauseRetryTask = nil
  }

  private func mediaRemotePlayingChanged(_ playing: Bool?) {
    guard playing == true,
      airPodsWearBehavior.shouldRemainPausedAfterRemoval,
      relayEngine?.isRunning == true
    else {
      return
    }

    let now = Date.timeIntervalSinceReferenceDate
    guard lastAdapterPauseReassertion.map({ now - $0 >= 0.2 }) ?? true else { return }
    lastAdapterPauseReassertion = now
    _ = sendMediaPause()
  }

  @discardableResult
  private func sendMediaPause() -> Bool {
    if mediaRemoteAdapter.pause() {
      return true
    }
    return mediaPauseController.pause()
  }

  @discardableResult
  private func sendMediaPlay() -> Bool {
    if mediaRemoteAdapter.play() {
      return true
    }
    return mediaPauseController.play()
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

private struct RelayRenderCallbackStalledError: LocalizedError {
  var errorDescription: String? {
    "物理输出音频回调没有产生新的渲染帧"
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
