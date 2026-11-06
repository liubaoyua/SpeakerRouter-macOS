import CoreAudio
import Foundation
import SpeakerRouterAudioSupport

public struct AppAudioClient: Sendable {
  public let registration: Int64
  public let pid: pid_t
  public let bundleID: String
  public let isActive: Bool
  public let targetGain: Float
}

// Keep synchronous HAL IPC off the menu's main actor.
public actor AppVolumeDriver {
  public init() {}

  public func snapshot(deviceID: AudioObjectID) throws -> [AppAudioClient] {
    var address = Self.address
    var property: Unmanaged<CFArray>?
    var size = UInt32(MemoryLayout.size(ofValue: property))
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &property)
    guard status == noErr,
      let rows = property?.takeRetainedValue() as? [[String: Any]]
    else {
      throw AudioRelayEngineError.operation("Read App volumes", status)
    }
    return rows.compactMap { row in
      guard let registration = row["registration"] as? Int64,
        let pid = row["pid"] as? pid_t,
        let bundleID = row["bundleID"] as? String,
        let isActive = row["active"] as? Bool,
        let targetGain = row["gain"] as? Float
      else { return nil }
      return AppAudioClient(
        registration: registration, pid: pid, bundleID: bundleID, isActive: isActive,
        targetGain: targetGain
      )
    }
  }

  public func setTargets(_ targets: [Int64: Float], deviceID: AudioObjectID) throws {
    let property = targets.map {
      ["registration": NSNumber(value: $0.key), "gain": NSNumber(value: $0.value)]
    } as CFArray
    var address = Self.address
    let status = withUnsafePointer(to: property) {
      AudioObjectSetPropertyData(
        deviceID, &address, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0
      )
    }
    guard status == noErr else {
      throw AudioRelayEngineError.operation("Set App volumes", status)
    }
  }

  private static var address: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: SRAppVolumePropertySelector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }
}
