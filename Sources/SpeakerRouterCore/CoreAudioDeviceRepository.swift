import CoreAudio
import Foundation

public enum CoreAudioDeviceRepositoryError: Error {
  case propertySize(OSStatus)
  case propertyRead(OSStatus)
}

public struct CoreAudioDeviceRepository: Sendable {
  public init() {}

  public func outputDevices() throws -> [OutputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &byteCount
    )
    guard status == noErr else {
      throw CoreAudioDeviceRepositoryError.propertySize(status)
    }

    var objectIDs = [AudioObjectID](
      repeating: kAudioObjectUnknown,
      count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
    )
    status = objectIDs.withUnsafeMutableBytes { buffer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount,
        buffer.baseAddress!
      )
    }
    guard status == noErr else {
      throw CoreAudioDeviceRepositoryError.propertyRead(status)
    }

    return objectIDs.compactMap(makeOutputDevice).sorted {
      if $0.kind.defaultRank != $1.kind.defaultRank {
        return $0.kind.defaultRank < $1.kind.defaultRank
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private func makeOutputDevice(objectID: AudioObjectID) -> OutputDevice? {
    guard hasOutputStreams(objectID: objectID), isAlive(objectID: objectID) else {
      return nil
    }

    let transport = transportType(objectID: objectID)
    guard transport != .virtual, transport != .aggregate else { return nil }

    guard
      let hardwareUID = stringProperty(
        objectID: objectID,
        selector: kAudioDevicePropertyDeviceUID
      )
    else { return nil }

    let deviceName =
      stringProperty(
        objectID: objectID,
        selector: kAudioObjectPropertyName
      ) ?? hardwareUID
    let manufacturer =
      stringProperty(
        objectID: objectID,
        selector: kAudioObjectPropertyManufacturer
      ) ?? ""
    let dataSourceID = optionalUInt32Property(
      objectID: objectID,
      selector: kAudioDevicePropertyDataSource,
      scope: kAudioDevicePropertyScopeOutput
    )
    let dataSourceName: String? = dataSourceID.flatMap {
      dataSourceDisplayName(objectID: objectID, dataSourceID: $0)
    }
    let name: String
    let uid: String
    if transport == .builtIn, let dataSourceID {
      name = dataSourceName ?? deviceName
      uid = "\(hardwareUID)::source:\(dataSourceID)"
    } else {
      name = deviceName
      uid = hardwareUID
    }
    let classificationText = [deviceName, dataSourceName]
      .compactMap { $0 }
      .joined(separator: " ")
    let kind = classify(name: classificationText, transport: transport)

    return OutputDevice(
      objectID: objectID,
      uid: uid,
      hardwareUID: hardwareUID,
      name: name,
      manufacturer: manufacturer,
      transport: transport,
      kind: kind,
      dataSourceID: dataSourceID,
      dataSourceName: dataSourceName
    )
  }

  private func hasOutputStreams(objectID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    return AudioObjectGetPropertyDataSize(
      objectID,
      &address,
      0,
      nil,
      &byteCount
    ) == noErr && byteCount > 0
  }

  private func isAlive(objectID: AudioObjectID) -> Bool {
    uint32Property(
      objectID: objectID,
      selector: kAudioDevicePropertyDeviceIsAlive
    ) != 0
  }

  private func transportType(objectID: AudioObjectID) -> OutputDeviceTransport {
    let value = uint32Property(
      objectID: objectID,
      selector: kAudioDevicePropertyTransportType
    )
    switch value {
    case kAudioDeviceTransportTypeBuiltIn: return .builtIn
    case kAudioDeviceTransportTypeBluetooth: return .bluetooth
    case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
    case kAudioDeviceTransportTypeUSB: return .usb
    case kAudioDeviceTransportTypeHDMI: return .hdmi
    case kAudioDeviceTransportTypeDisplayPort: return .displayPort
    case kAudioDeviceTransportTypeAirPlay: return .airPlay
    case kAudioDeviceTransportTypeVirtual: return .virtual
    case kAudioDeviceTransportTypeAggregate: return .aggregate
    default: return .unknown
    }
  }

  private func classify(
    name: String,
    transport: OutputDeviceTransport
  ) -> OutputDeviceKind {
    let normalized = name.lowercased()
    let headphoneTerms = [
      "airpods", "earpods", "headphone", "headset", "earphone",
      "earbuds", "buds", "耳机",
    ]
    let nameLooksLikeHeadphones = headphoneTerms.contains {
      normalized.contains($0)
    }

    switch transport {
    case .bluetooth, .bluetoothLE:
      return .headphones
    case .hdmi, .displayPort:
      return .display
    case .builtIn:
      return nameLooksLikeHeadphones ? .headphones : .builtInSpeaker
    case .usb:
      return nameLooksLikeHeadphones ? .headphones : .other
    default:
      return nameLooksLikeHeadphones ? .headphones : .other
    }
  }

  private func uint32Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> UInt32 {
    optionalUInt32Property(
      objectID: objectID,
      selector: selector,
      scope: kAudioObjectPropertyScopeGlobal
    ) ?? 0
  }

  private func optionalUInt32Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var byteCount = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      objectID,
      &address,
      0,
      nil,
      &byteCount,
      &value
    )
    return status == noErr ? value : nil
  }

  private func dataSourceDisplayName(
    objectID: AudioObjectID,
    dataSourceID: UInt32
  ) -> String? {
    var sourceID = dataSourceID
    var result: CFString = "" as CFString
    let status: OSStatus = withUnsafeMutablePointer(to: &sourceID) { inputPointer in
      withUnsafeMutablePointer(to: &result) { outputPointer in
        var translation = AudioValueTranslation(
          mInputData: inputPointer,
          mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
          mOutputData: outputPointer,
          mOutputDataSize: UInt32(MemoryLayout<CFString>.size)
        )
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
          mScope: kAudioDevicePropertyScopeOutput,
          mElement: kAudioObjectPropertyElementMain
        )
        var byteCount = UInt32(MemoryLayout<AudioValueTranslation>.size)
        return AudioObjectGetPropertyData(
          objectID,
          &address,
          0,
          nil,
          &byteCount,
          &translation
        )
      }
    }
    return status == noErr ? result as String : nil
  }

  private func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var byteCount = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &byteCount,
        pointer
      )
    }
    return status == noErr ? value as String : nil
  }
}
