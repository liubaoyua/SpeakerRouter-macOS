import Foundation
import Testing

@testable import SpeakerRouterCore

@Suite("Routing state")
struct RoutingStateTests {
  @Test("Guard heartbeat persists its recovery target")
  func guardHeartbeatRoundTrip() throws {
    let heartbeat = GuardHeartbeat(
      parentProcessID: 42,
      fallbackDeviceUID: "physical-output",
      updatedAt: Date(timeIntervalSince1970: 1234),
      cleanShutdown: false
    )

    let data = try JSONEncoder().encode(heartbeat)
    let decoded = try JSONDecoder().decode(GuardHeartbeat.self, from: data)

    #expect(decoded == heartbeat)
  }

  @Test("Volume uses a perceptual square-law gain curve")
  func volumeCurve() {
    #expect(VolumeCurve.gain(for: -1) == 0)
    #expect(VolumeCurve.gain(for: 0.5) == 0.25)
    #expect(VolumeCurve.gain(for: 1) == 1)
    #expect(VolumeCurve.gain(for: 2) == 1)
  }

  @Test("New devices receive the default category order")
  func defaultCategoryOrder() {
    var state = RoutingState()
    let devices = [
      device("speaker", kind: .builtInSpeaker),
      device("display", kind: .display),
      device("headphones", kind: .headphones),
    ]

    state.reconcile(with: devices)

    #expect(state.preferences.map(\.uid) == ["headphones", "display", "speaker"])
    #expect(state.selectedDeviceUID(from: devices) == "headphones")
  }

  @Test("Manual selection overrides a higher priority device")
  func manualLockWins() {
    let devices = [
      device("headphones", kind: .headphones),
      device("display", kind: .display),
    ]
    var state = RoutingState()
    state.reconcile(with: devices)
    state.selectManually(uid: "display", discovered: devices)

    #expect(state.selectedDeviceUID(from: devices) == "display")
    #expect(state.manualLockedDeviceUID == "display")
  }

  @Test("A newly connected higher priority device does not break a manual lock")
  func newDeviceDoesNotBreakManualLock() {
    let displayOnly = [device("display", kind: .display)]
    var state = RoutingState()
    state.reconcile(with: displayOnly)
    state.selectManually(uid: "display", discovered: displayOnly)

    let withHeadphones = displayOnly + [device("headphones", kind: .headphones)]
    state.reconcile(with: withHeadphones)

    #expect(state.selectedDeviceUID(from: withHeadphones) == "display")
  }

  @Test("Disconnecting a manually selected device clears the lock")
  func disconnectClearsManualLock() {
    let allDevices = [
      device("headphones", kind: .headphones),
      device("display", kind: .display),
      device("speaker", kind: .builtInSpeaker),
    ]
    var state = RoutingState()
    state.reconcile(with: allDevices)
    state.selectManually(uid: "display", discovered: allDevices)

    let remaining = [
      device("headphones", kind: .headphones),
      device("speaker", kind: .builtInSpeaker),
    ]
    state.reconcile(with: remaining)

    #expect(state.manualLockedDeviceUID == nil)
    #expect(state.selectedDeviceUID(from: remaining) == "headphones")
  }

  @Test("Only disconnecting the active headphones requests a media pause")
  func headphoneDisconnectPausePolicy() {
    let headphones = device("headphones", kind: .headphones)
    let display = device("display", kind: .display)

    #expect(
      DeviceDisconnectBehavior.shouldPauseMedia(
        activeDeviceUID: headphones.uid,
        previousDevices: [headphones, display],
        currentDevices: [display]
      )
    )
    #expect(
      !DeviceDisconnectBehavior.shouldPauseMedia(
        activeDeviceUID: display.uid,
        previousDevices: [headphones, display],
        currentDevices: [headphones]
      )
    )
    #expect(
      !DeviceDisconnectBehavior.shouldPauseMedia(
        activeDeviceUID: headphones.uid,
        previousDevices: [headphones, display],
        currentDevices: [headphones, display]
      )
    )
  }

  @Test("AirPods proximity status decodes either ear as worn")
  func airPodsProximityStatus() {
    let bothInEar = Data([
      0x4C, 0x00, 0x07, 0x19, 0x01, 0x1B, 0x20, 0x0B,
      0x99, 0x8F, 0x11, 0x00, 0x05, 0x05, 0x5E, 0x5F,
    ])
    var neitherInEar = bothInEar
    neitherInEar[7] = 0x15
    var primaryInEar = bothInEar
    primaryInEar[7] = 0x13

    #expect(
      AirPodsProximityAdvertisement.wearState(from: bothInEar)
        == AirPodsWearState(primaryInEar: true, secondaryInEar: true)
    )
    #expect(
      AirPodsProximityAdvertisement.wearState(from: primaryInEar)
        == AirPodsWearState(primaryInEar: true, secondaryInEar: false)
    )
    #expect(
      AirPodsProximityAdvertisement.wearState(from: neitherInEar)
        == AirPodsWearState(primaryInEar: false, secondaryInEar: false)
    )
    #expect(AirPodsProximityAdvertisement.wearState(from: Data([0x4C, 0x00])) == nil)
  }

  @Test("Connected AirPods placement log events decode only for the active address")
  func airPodsPlacementLogParsing() {
    let address = "C4:B3:49:90:52:ED"
    let oneWorn =
      "received in-ear state update from device C4:B3:49:90:52:ED "
      + "primary bud state = in ear, secondary bud state = out of ear"
    let neitherWorn =
      "received in-ear state update from device C4:B3:49:90:52:ED "
      + "primary bud state = out of ear, secondary bud state = in case"

    #expect(
      AirPodsPlacementLogParser.wearState(from: oneWorn, targetAddress: address)
        == AirPodsWearState(primaryInEar: true, secondaryInEar: false)
    )
    #expect(
      AirPodsPlacementLogParser.wearState(from: neitherWorn, targetAddress: address)
        == AirPodsWearState(primaryInEar: false, secondaryInEar: false)
    )
    #expect(
      AirPodsPlacementLogParser.wearState(
        from: oneWorn,
        targetAddress: "00:11:22:33:44:55"
      ) == nil
    )
  }

  @Test("AirPods resume only after a confirmed removal pause")
  func airPodsWearPlaybackPolicy() {
    var behavior = AirPodsWearPlaybackBehavior()
    let bothWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: true)
    let oneWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: false)

    #expect(behavior.observe(bothWorn) == nil)
    #expect(behavior.observe(oneWorn) == .requestPause)
    #expect(behavior.observe(bothWorn) == nil)

    #expect(behavior.observe(oneWorn) == .requestPause)
    behavior.confirmPausedForRemoval()
    #expect(behavior.shouldRemainPausedAfterRemoval)
    #expect(behavior.observe(bothWorn) == .requestPlay)
    #expect(behavior.shouldRemainPausedAfterRemoval)
    behavior.confirmResumedAfterReinsertion()
    #expect(!behavior.shouldRemainPausedAfterRemoval)
    #expect(behavior.observe(bothWorn) == nil)
  }

  @Test("A delayed pause confirmation cannot resume after AirPods are already worn")
  func delayedAirPodsPauseConfirmation() {
    var behavior = AirPodsWearPlaybackBehavior()
    let bothWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: true)
    let oneWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: false)

    #expect(behavior.observe(bothWorn) == nil)
    #expect(behavior.observe(oneWorn) == .requestPause)
    #expect(behavior.observe(bothWorn) == nil)
    behavior.confirmPausedForRemoval()

    #expect(behavior.observe(oneWorn) == .requestPause)
  }

  @Test("Removing the second AirPod preserves the confirmed resume")
  func removingSecondAirPodPreservesResume() {
    var behavior = AirPodsWearPlaybackBehavior()
    let bothWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: true)
    let oneWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: false)
    let neitherWorn = AirPodsWearState(primaryInEar: false, secondaryInEar: false)

    #expect(behavior.observe(bothWorn) == nil)
    #expect(behavior.observe(oneWorn) == .requestPause)
    behavior.confirmPausedForRemoval()
    #expect(behavior.observe(neitherWorn) == nil)
    #expect(behavior.observe(oneWorn) == .requestPlay)
  }

  @Test("A transient worn-again sensor state does not clear the removal pause")
  func transientAirPodsReinsertion() {
    var behavior = AirPodsWearPlaybackBehavior()
    let bothWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: true)
    let oneWorn = AirPodsWearState(primaryInEar: true, secondaryInEar: false)

    #expect(behavior.observe(bothWorn) == nil)
    #expect(behavior.observe(oneWorn) == .requestPause)
    behavior.confirmPausedForRemoval()

    #expect(behavior.observe(bothWorn) == .requestPlay)
    #expect(behavior.observe(oneWorn) == nil)
    #expect(behavior.shouldRemainPausedAfterRemoval)
    #expect(behavior.observe(bothWorn) == .requestPlay)
  }

  @Test("MediaRemote state wins, with recent audio used only when it is unavailable")
  func mediaPlaybackPauseDecision() {
    #expect(
      MediaPlaybackPauseDecision.shouldPause(
        adapterPlaying: true,
        fallbackHasRecentAudio: false
      )
    )
    #expect(
      !MediaPlaybackPauseDecision.shouldPause(
        adapterPlaying: false,
        fallbackHasRecentAudio: true
      )
    )
    #expect(
      MediaPlaybackPauseDecision.shouldPause(
        adapterPlaying: nil,
        fallbackHasRecentAudio: true
      )
    )
    #expect(
      !MediaPlaybackPauseDecision.shouldPause(
        adapterPlaying: nil,
        fallbackHasRecentAudio: false
      )
    )
  }

  @Test("Device volume is remembered and clamped")
  func perDeviceVolume() {
    let display = device("display", kind: .display)
    var state = RoutingState()
    state.reconcile(with: [display])

    #expect(state.volume(for: display.uid) == 0.3)
    state.setVolume(0.72, for: display.uid)
    #expect(state.volume(for: display.uid) == 0.72)
    state.setVolume(2, for: display.uid)
    #expect(state.volume(for: display.uid) == 1)
    state.setVolume(-1, for: display.uid)
    #expect(state.volume(for: display.uid) == 0)
  }

  @Test("State persists manual lock, order, and volume")
  func persistenceRoundTrip() throws {
    let devices = [
      device("display", kind: .display),
      device("speaker", kind: .builtInSpeaker),
    ]
    var state = RoutingState()
    state.reconcile(with: devices)
    state.moveDevice(uid: "speaker", to: 0)
    state.selectManually(uid: "display", discovered: devices)
    state.setVolume(0.64, for: "display")

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(RoutingState.self, from: data)

    #expect(decoded == state)
    #expect(decoded.preferences.map(\.uid) == ["speaker", "display"])
    #expect(decoded.manualLockedDeviceUID == "display")
    #expect(decoded.volume(for: "display") == 0.64)
  }

  @Test("Rediscovery updates metadata without changing custom order")
  func rediscoveryKeepsCustomOrder() {
    var state = RoutingState()
    let initial = [
      device("display", kind: .display),
      device("speaker", kind: .builtInSpeaker),
    ]
    state.reconcile(with: initial)
    state.moveDevice(uid: "speaker", to: 0)

    let renamedDisplay = OutputDevice(
      objectID: 2,
      uid: "display",
      name: "Renamed display",
      manufacturer: "Test",
      transport: .hdmi,
      kind: .display
    )
    state.reconcile(with: [renamedDisplay, initial[1]])

    #expect(state.preferences.map(\.uid) == ["speaker", "display"])
    #expect(state.preferences[1].lastKnownName == "Renamed display")
    #expect(state.preferences[1].transport == .hdmi)
  }

  private func device(
    _ uid: String,
    kind: OutputDeviceKind
  ) -> OutputDevice {
    OutputDevice(
      objectID: 1,
      uid: uid,
      name: uid.capitalized,
      manufacturer: "Test",
      transport: transport(for: kind),
      kind: kind
    )
  }

  private func transport(for kind: OutputDeviceKind) -> OutputDeviceTransport {
    switch kind {
    case .headphones: .bluetooth
    case .display: .displayPort
    case .builtInSpeaker: .builtIn
    case .other: .usb
    }
  }
}
