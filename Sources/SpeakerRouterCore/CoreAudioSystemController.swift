import CoreAudio
import Foundation

public struct CoreAudioOperationError: Error, CustomStringConvertible, Sendable {
  public let operation: String
  public let status: OSStatus

  public init(operation: String, status: OSStatus) {
    self.operation = operation
    self.status = status
  }

  public var description: String {
    "\(operation) failed with Core Audio status \(status)"
  }
}

public struct CoreAudioSystemController: Sendable {
  public static let speakerRouterDeviceUID = "SpeakerRouterHAL_Device_UID"

  public init() {}

  public func deviceID(forUID uid: String) throws -> AudioObjectID? {
    for deviceID in try allDeviceIDs() {
      if stringProperty(
        objectID: deviceID,
        selector: kAudioDevicePropertyDeviceUID
      ) == uid {
        return deviceID
      }
    }
    return nil
  }

  public func deviceUID(for deviceID: AudioObjectID) -> String? {
    stringProperty(
      objectID: deviceID,
      selector: kAudioDevicePropertyDeviceUID
    )
  }

  public func defaultOutputDeviceID() throws -> AudioObjectID {
    try audioObjectIDProperty(
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      operation: "Read default output"
    )
  }

  public func defaultSystemOutputDeviceID() throws -> AudioObjectID {
    try audioObjectIDProperty(
      selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
      operation: "Read system-sound output"
    )
  }

  public func setDefaultOutputs(to deviceID: AudioObjectID) throws {
    let previousDefaultOutput = try defaultOutputDeviceID()
    let previousSystemOutput = try defaultSystemOutputDeviceID()
    try setSystemDeviceProperty(
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      deviceID: deviceID,
      operation: "Set default output"
    )
    do {
      try setSystemDeviceProperty(
        selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        deviceID: deviceID,
        operation: "Set system-sound output"
      )
    } catch {
      // Avoid leaving application audio and system sounds split after a partial update.
      try? setSystemDeviceProperty(
        selector: kAudioHardwarePropertyDefaultOutputDevice,
        deviceID: previousDefaultOutput,
        operation: "Roll back default output"
      )
      try? setSystemDeviceProperty(
        selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        deviceID: previousSystemOutput,
        operation: "Roll back system-sound output"
      )
      throw error
    }
  }

  public func outputVolume(of deviceID: AudioObjectID) -> Float? {
    floatProperty(
      objectID: deviceID,
      selector: kAudioDevicePropertyVolumeScalar,
      scope: kAudioDevicePropertyScopeOutput
    )
  }

  public func outputMute(of deviceID: AudioObjectID) -> Bool {
    uint32Property(
      objectID: deviceID,
      selector: kAudioDevicePropertyMute,
      scope: kAudioDevicePropertyScopeOutput
    ) != 0
  }

  public func setOutputVolume(_ volume: Float, of deviceID: AudioObjectID) throws {
    var clamped = min(max(volume, 0), 1)
    try setDeviceProperty(
      objectID: deviceID,
      selector: kAudioDevicePropertyVolumeScalar,
      scope: kAudioDevicePropertyScopeOutput,
      value: &clamped,
      operation: "Set output volume"
    )
  }

  public func setOutputMute(_ muted: Bool, of deviceID: AudioObjectID) throws {
    var value: UInt32 = muted ? 1 : 0
    try setDeviceProperty(
      objectID: deviceID,
      selector: kAudioDevicePropertyMute,
      scope: kAudioDevicePropertyScopeOutput,
      value: &value,
      operation: "Set output mute"
    )
  }

  private func allDeviceIDs() throws -> [AudioObjectID] {
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
      throw CoreAudioOperationError(operation: "Read audio device list size", status: status)
    }

    var deviceIDs = [AudioObjectID](
      repeating: kAudioObjectUnknown,
      count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
    )
    status = deviceIDs.withUnsafeMutableBytes { buffer in
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
      throw CoreAudioOperationError(operation: "Read audio device list", status: status)
    }
    return deviceIDs
  }

  private func audioObjectIDProperty(
    selector: AudioObjectPropertySelector,
    operation: String
  ) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = AudioObjectID(kAudioObjectUnknown)
    var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &byteCount,
      &value
    )
    guard status == noErr else {
      throw CoreAudioOperationError(operation: operation, status: status)
    }
    return value
  }

  private func setSystemDeviceProperty(
    selector: AudioObjectPropertySelector,
    deviceID: AudioObjectID,
    operation: String
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = deviceID
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      UInt32(MemoryLayout<AudioObjectID>.size),
      &value
    )
    guard status == noErr else {
      throw CoreAudioOperationError(operation: operation, status: status)
    }
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

  private func floatProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) -> Float? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Float = 0
    var byteCount = UInt32(MemoryLayout<Float>.size)
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

  private func uint32Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) -> UInt32 {
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
    return status == noErr ? value : 0
  }

  private func setDeviceProperty<T: BitwiseCopyable>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    value: inout T,
    operation: String
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectSetPropertyData(
      objectID,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<T>.size),
      &value
    )
    guard status == noErr else {
      throw CoreAudioOperationError(operation: operation, status: status)
    }
  }
}
