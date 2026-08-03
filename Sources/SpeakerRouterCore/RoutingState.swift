import Foundation

public struct RoutingState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public private(set) var preferences: [DevicePreference]
  public private(set) var manualLockedDeviceUID: String?
  public var lastUsablePhysicalDeviceUID: String?

  public init(
    schemaVersion: Int = RoutingState.currentSchemaVersion,
    preferences: [DevicePreference] = [],
    manualLockedDeviceUID: String? = nil,
    lastUsablePhysicalDeviceUID: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.preferences = preferences
    self.manualLockedDeviceUID = manualLockedDeviceUID
    self.lastUsablePhysicalDeviceUID = lastUsablePhysicalDeviceUID
  }

  public mutating func reconcile(with discovered: [OutputDevice]) {
    let discoveredByUID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.uid, $0) })

    for index in preferences.indices {
      guard let live = discoveredByUID[preferences[index].uid] else { continue }
      preferences[index].lastKnownName = live.name
      preferences[index].kind = live.kind
      preferences[index].transport = live.transport
    }

    for device in discovered where !preferences.contains(where: { $0.uid == device.uid }) {
      let preference = DevicePreference(
        uid: device.uid,
        lastKnownName: device.name,
        kind: device.kind,
        transport: device.transport
      )
      let insertionIndex =
        preferences.firstIndex {
          $0.kind.defaultRank > device.kind.defaultRank
        } ?? preferences.endIndex
      preferences.insert(preference, at: insertionIndex)
    }

    if let lockedUID = manualLockedDeviceUID, discoveredByUID[lockedUID] == nil {
      manualLockedDeviceUID = nil
    }
  }

  public func rows(with discovered: [OutputDevice]) -> [RoutableOutputDevice] {
    let discoveredByUID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.uid, $0) })
    return preferences.map {
      RoutableOutputDevice(preference: $0, liveDevice: discoveredByUID[$0.uid])
    }
  }

  public func selectedDeviceUID(from discovered: [OutputDevice]) -> String? {
    let onlineUIDs = Set(discovered.map(\.uid))
    if let lockedUID = manualLockedDeviceUID, onlineUIDs.contains(lockedUID) {
      return lockedUID
    }
    return preferences.first(where: { onlineUIDs.contains($0.uid) })?.uid
  }

  public mutating func selectManually(uid: String, discovered: [OutputDevice]) {
    guard discovered.contains(where: { $0.uid == uid }) else { return }
    manualLockedDeviceUID = uid
    lastUsablePhysicalDeviceUID = uid
  }

  public mutating func returnToAutomaticRouting() {
    manualLockedDeviceUID = nil
  }

  public mutating func moveDevice(uid: String, to destination: Int) {
    guard let source = preferences.firstIndex(where: { $0.uid == uid }) else { return }
    let item = preferences.remove(at: source)
    let boundedDestination = min(max(destination, 0), preferences.count)
    preferences.insert(item, at: boundedDestination)
  }

  public mutating func setVolume(_ volume: Double, for uid: String) {
    guard let index = preferences.firstIndex(where: { $0.uid == uid }) else { return }
    preferences[index].volume = min(max(volume, 0), 1)
  }

  public func volume(for uid: String) -> Double {
    preferences.first(where: { $0.uid == uid })?.volume ?? 0.3
  }
}
