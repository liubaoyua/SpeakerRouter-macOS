import Testing
@testable import SpeakerRouterCore

@Suite("AirPods hidden output recovery")
struct AirPodsRouteRecoveryTests {
  private let worn = AirPodsWearState(primaryInEar: true, secondaryInEar: true)
  private let removed = AirPodsWearState(primaryInEar: false, secondaryInEar: false)

  @Test("A hidden output waits for live wear evidence and reconnects only once")
  func liveEvidenceAndOneAttempt() {
    var recovery = AirPodsRouteRecovery()
    recovery.outputDisappeared(at: 0)
    let withoutWear = recovery.shouldReconnect(at: 3, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(!withoutWear)
    recovery.observeLiveWear(worn, at: 3)
    let tooEarly = recovery.shouldReconnect(at: 3.5, bluetoothConnected: true, routingAllowsTarget: true)
    let first = recovery.shouldReconnect(at: 4, bluetoothConnected: true, routingAllowsTarget: true)
    let second = recovery.shouldReconnect(at: 10, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(!tooEarly)
    #expect(first)
    #expect(!second)
  }

  @Test("Removing the buds again cancels worn evidence")
  func removalCancelsEvidence() {
    var recovery = AirPodsRouteRecovery()
    recovery.outputDisappeared(at: 0)
    recovery.observeLiveWear(worn, at: 1)
    recovery.observeLiveWear(removed, at: 1.5)
    let result = recovery.shouldReconnect(at: 4, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(!result)
  }

  @Test("A disconnected bud, manual choice, or expired window ends recovery")
  func cancellationBoundaries() {
    for (connected, allowsTarget, time) in [(false, true, 4.0), (true, false, 4.0), (true, true, 121.0)] {
      var recovery = AirPodsRouteRecovery()
      recovery.outputDisappeared(at: 0)
      recovery.observeLiveWear(worn, at: 1)
      let result = recovery.shouldReconnect(at: time, bluetoothConnected: connected, routingAllowsTarget: allowsTarget)
      #expect(!result)
      #expect(!recovery.isWaiting)
    }
  }

  @Test("A reinsertion just before the device snapshot still permits recovery")
  func eventSnapshotOrdering() {
    var recovery = AirPodsRouteRecovery()
    recovery.observeLiveWear(removed, at: 0)
    recovery.observeLiveWear(worn, at: 1)
    recovery.outputDisappeared(at: 1.1)
    let result = recovery.shouldReconnect(at: 3.1, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(result)
  }

  @Test("A long removal keeps listening and starts its deadline on reinsertion")
  func longRemoval() {
    var recovery = AirPodsRouteRecovery()
    recovery.observeLiveWear(removed, at: 0)
    recovery.outputDisappeared(at: 1)
    let whileRemoved = recovery.shouldReconnect(at: 600, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(!whileRemoved)
    #expect(recovery.isWaiting)
    recovery.observeLiveWear(worn, at: 600)
    let afterReinsertion = recovery.shouldReconnect(at: 602, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(afterReinsertion)
  }

  @Test("Old worn evidence cannot reconnect a newly hidden output")
  func staleEvidence() {
    var recovery = AirPodsRouteRecovery()
    recovery.observeLiveWear(removed, at: 0)
    recovery.observeLiveWear(worn, at: 1)
    recovery.outputDisappeared(at: 10)
    let result = recovery.shouldReconnect(at: 13, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(!result)
  }

  @Test("Repeated output disappearance cannot cause a reconnect loop")
  func cooldownSurvivesSuccess() {
    var recovery = AirPodsRouteRecovery()
    recovery.outputDisappeared(at: 0)
    recovery.observeLiveWear(worn, at: 1)
    let first = recovery.shouldReconnect(at: 2, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(first)
    recovery.cancel()
    recovery.outputDisappeared(at: 3)
    recovery.observeLiveWear(worn, at: 4)
    let tooSoon = recovery.shouldReconnect(at: 5, bluetoothConnected: true, routingAllowsTarget: true)
    let afterCooldown = recovery.shouldReconnect(at: 32, bluetoothConnected: true, routingAllowsTarget: true)
    #expect(!tooSoon)
    #expect(afterCooldown)
  }

  @Test("Bluetooth routing UIDs resolve to an exact device address")
  func addresses() {
    #expect(BluetoothDeviceAddress.from(hardwareUID: "c4-b3-49-90-52-ed:output") == "C4:B3:49:90:52:ED")
    #expect(BluetoothDeviceAddress.from(hardwareUID: "C4:B3:49:90:52:ED") == "C4:B3:49:90:52:ED")
    #expect(BluetoothDeviceAddress.from(hardwareUID: "BuiltInSpeakerDevice") == nil)
    #expect(BluetoothDeviceAddress.from(hardwareUID: "GG:B3:49:90:52:ED") == nil)
  }
}
