import Foundation

public enum OutputDeviceKind: String, Codable, CaseIterable, Sendable {
  case headphones
  case display
  case builtInSpeaker
  case other

  public var defaultRank: Int {
    switch self {
    case .headphones: 0
    case .display: 1
    case .builtInSpeaker: 2
    case .other: 3
    }
  }
}

public enum OutputDeviceTransport: String, Codable, Sendable {
  case builtIn
  case bluetooth
  case bluetoothLE
  case usb
  case hdmi
  case displayPort
  case airPlay
  case virtual
  case aggregate
  case unknown
}

public struct OutputDevice: Identifiable, Hashable, Sendable {
  public let objectID: UInt32
  public let uid: String
  public let hardwareUID: String
  public let name: String
  public let manufacturer: String
  public let transport: OutputDeviceTransport
  public let kind: OutputDeviceKind
  public let dataSourceID: UInt32?
  public let dataSourceName: String?

  public var id: String { uid }

  public init(
    objectID: UInt32,
    uid: String,
    hardwareUID: String? = nil,
    name: String,
    manufacturer: String,
    transport: OutputDeviceTransport,
    kind: OutputDeviceKind,
    dataSourceID: UInt32? = nil,
    dataSourceName: String? = nil
  ) {
    self.objectID = objectID
    self.uid = uid
    self.hardwareUID = hardwareUID ?? uid
    self.name = name
    self.manufacturer = manufacturer
    self.transport = transport
    self.kind = kind
    self.dataSourceID = dataSourceID
    self.dataSourceName = dataSourceName
  }
}

public struct DevicePreference: Identifiable, Codable, Equatable, Sendable {
  public let uid: String
  public var lastKnownName: String
  public var kind: OutputDeviceKind
  public var transport: OutputDeviceTransport
  public var volume: Double

  public var id: String { uid }

  public init(
    uid: String,
    lastKnownName: String,
    kind: OutputDeviceKind,
    transport: OutputDeviceTransport,
    volume: Double = 0.3
  ) {
    self.uid = uid
    self.lastKnownName = lastKnownName
    self.kind = kind
    self.transport = transport
    self.volume = min(max(volume, 0), 1)
  }
}

public struct RoutableOutputDevice: Identifiable, Equatable, Sendable {
  public let preference: DevicePreference
  public let liveDevice: OutputDevice?

  public var id: String { preference.uid }
  public var isOnline: Bool { liveDevice != nil }
  public var displayName: String { liveDevice?.name ?? preference.lastKnownName }
}
