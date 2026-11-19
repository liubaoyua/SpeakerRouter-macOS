import Foundation

/// A recovery episode requires fresh placement evidence, not the monitor's
/// synthetic startup baseline. It never reconnects a genuinely disconnected bud.
public struct AirPodsRouteRecovery: Sendable {
  private var missingSince: TimeInterval?
  private var wornSince: TimeInterval?
  private var lastInEarCount: Int?
  private var attempted = false
  private var lastAttemptTime: TimeInterval?

  public init() {}

  public var isWaiting: Bool { missingSince != nil }

  public mutating func observeLiveWear(_ state: AirPodsWearState, at time: TimeInterval) {
    if state.inEarCount == 0 {
      wornSince = nil
    } else if missingSince != nil || state.inEarCount > (lastInEarCount ?? 2) {
      if wornSince == nil { wornSince = time }
    }
    lastInEarCount = state.inEarCount
  }

  public mutating func outputDisappeared(at time: TimeInterval) {
    guard missingSince == nil else { return }
    missingSince = time
    attempted = false
    // Handle a reinsertion event delivered immediately before the device snapshot.
    if let wornSince, time - wornSince > 3 { self.wornSince = nil }
  }

  public mutating func cancel() {
    missingSince = nil
    wornSince = nil
    lastInEarCount = nil
    attempted = false
  }

  public mutating func shouldReconnect(
    at time: TimeInterval,
    bluetoothConnected: Bool,
    routingAllowsTarget: Bool
  ) -> Bool {
    guard let missingSince else { return false }
    let expired = wornSince.map { time - $0 >= 120 } ?? false
    guard bluetoothConnected, routingAllowsTarget, !expired else {
      cancel()
      return false
    }
    guard !attempted, let wornSince,
      time - missingSince >= 2, time - wornSince >= 1,
      lastAttemptTime.map({ time - $0 >= 30 }) ?? true
    else { return false }
    attempted = true
    lastAttemptTime = time
    return true
  }
}

public enum BluetoothDeviceAddress {
  public static func from(hardwareUID: String) -> String? {
    let components = hardwareUID.uppercased()
      .replacingOccurrences(of: ":", with: "-").split(separator: "-")
    guard components.count >= 6 else { return nil }
    let parts = components.prefix(6)
    guard parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
      return nil
    }
    return parts.joined(separator: ":")
  }
}
