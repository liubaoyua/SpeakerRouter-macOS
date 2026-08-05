import Foundation

public struct AirPodsWearState: Equatable, Sendable {
  public let primaryInEar: Bool
  public let secondaryInEar: Bool

  public init(primaryInEar: Bool, secondaryInEar: Bool) {
    self.primaryInEar = primaryInEar
    self.secondaryInEar = secondaryInEar
  }

  public var inEarCount: Int {
    (primaryInEar ? 1 : 0) + (secondaryInEar ? 1 : 0)
  }
}

public enum AirPodsWearPlaybackAction: Equatable, Sendable {
  case requestPause
  case requestPlay
}

public struct AirPodsWearPlaybackBehavior: Sendable {
  private var lastWearState: AirPodsWearState?
  private var pausedForRemoval = false
  private var pauseRequestPending = false

  public init() {}

  public var shouldRemainPausedAfterRemoval: Bool {
    pausedForRemoval
  }

  public mutating func reset() {
    lastWearState = nil
    pausedForRemoval = false
    pauseRequestPending = false
  }

  public mutating func observe(
    _ wearState: AirPodsWearState
  ) -> AirPodsWearPlaybackAction? {
    defer { lastWearState = wearState }
    guard let lastWearState,
      lastWearState.inEarCount != wearState.inEarCount
    else {
      return nil
    }

    if wearState.inEarCount < lastWearState.inEarCount {
      guard !pausedForRemoval, !pauseRequestPending else { return nil }
      pauseRequestPending = true
      return .requestPause
    } else {
      pauseRequestPending = false
      guard pausedForRemoval else { return nil }
      return .requestPlay
    }
  }

  public mutating func confirmPausedForRemoval() {
    guard pauseRequestPending else { return }
    pauseRequestPending = false
    pausedForRemoval = true
  }

  public mutating func cancelPauseRequest() {
    pauseRequestPending = false
  }

  public mutating func confirmResumedAfterReinsertion() {
    pausedForRemoval = false
  }
}

public struct RecentAudioActivityTracker: Sendable {
  private let maximumIdleInterval: TimeInterval
  private var previousWrittenFrames: UInt64?
  private var lastProgressTime: TimeInterval?

  public init(maximumIdleInterval: TimeInterval = 2) {
    self.maximumIdleInterval = maximumIdleInterval
  }

  public mutating func reset() {
    previousWrittenFrames = nil
    lastProgressTime = nil
  }

  public mutating func observe(
    writtenFrames: UInt64,
    at time: TimeInterval
  ) {
    if let previousWrittenFrames {
      if writtenFrames > previousWrittenFrames {
        lastProgressTime = time
      } else if writtenFrames < previousWrittenFrames {
        lastProgressTime = nil
      }
    }
    previousWrittenFrames = writtenFrames
  }

  public func hasRecentActivity(at time: TimeInterval) -> Bool {
    guard let lastProgressTime, time >= lastProgressTime else { return false }
    return time - lastProgressTime <= maximumIdleInterval
  }
}

public enum MediaPlaybackPauseDecision {
  public static func shouldPause(
    adapterPlaying: Bool?,
    fallbackHasRecentAudio: Bool
  ) -> Bool {
    adapterPlaying ?? fallbackHasRecentAudio
  }
}

public enum AirPodsProximityAdvertisement {
  public static func wearState(from manufacturerData: Data) -> AirPodsWearState? {
    let bytes = [UInt8](manufacturerData)
    guard bytes.count >= 8,
      bytes[0] == 0x4C,
      bytes[1] == 0x00,
      bytes[2] == 0x07,
      bytes[3] >= 0x06
    else {
      return nil
    }

    // Apple proximity-pairing status packets encode each bud's placement in two bits.
    // Location 1 means in-ear; the remaining values cover out-of-ear, in-case, or unknown.
    let placement = bytes[7]
    let primaryLocation = (placement >> 1) & 0x03
    let secondaryLocation = (placement >> 3) & 0x03
    return AirPodsWearState(
      primaryInEar: primaryLocation == 1,
      secondaryInEar: secondaryLocation == 1
    )
  }
}

public enum AirPodsPlacementLogParser {
  public static func wearState(
    from eventMessage: String,
    targetAddress: String
  ) -> AirPodsWearState? {
    let message = eventMessage.lowercased()
    guard message.contains(targetAddress.lowercased()),
      let primary = placement(
        in: message,
        after: "primary bud state = ",
        before: ", secondary bud state = "
      ),
      let secondaryStart = message.range(of: ", secondary bud state = ")?.upperBound
    else {
      return nil
    }

    let secondary = String(message[secondaryStart...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return AirPodsWearState(
      primaryInEar: primary == "in ear",
      secondaryInEar: secondary == "in ear"
    )
  }

  private static func placement(
    in message: String,
    after prefix: String,
    before suffix: String
  ) -> String? {
    guard let start = message.range(of: prefix)?.upperBound,
      let end = message.range(of: suffix, range: start..<message.endIndex)?.lowerBound
    else {
      return nil
    }
    return String(message[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
