import AudioToolbox
import CoreAudio
import Foundation
import SpeakerRouterAudioSupport

public enum AudioRelayEngineError: Error, CustomStringConvertible, Sendable {
  case sharedTransport(String)
  case audioUnitComponentMissing
  case operation(String, OSStatus)

  public var description: String {
    switch self {
    case .sharedTransport(let message):
      "Shared audio transport failed: \(message)"
    case .audioUnitComponentMissing:
      "The HAL output audio unit is unavailable"
    case .operation(let name, let status):
      "\(name) failed with Core Audio status \(status)"
    }
  }
}

public struct AudioRelayStatistics: Codable, Equatable, Sendable {
  public let capturedFrames: UInt64
  public let requestedRenderFrames: UInt64
  public let nonSilentCapturedSamples: UInt64
  public let nonSilentRenderedSamples: UInt64
  public let underflowFrames: UInt64

  public var hasRenderedSignal: Bool {
    capturedFrames > 0
      && requestedRenderFrames > 0
      && nonSilentCapturedSamples > 0
      && nonSilentRenderedSamples > 0
  }

  public func renderCallbackAdvanced(since previous: AudioRelayStatistics) -> Bool {
    requestedRenderFrames > previous.requestedRenderFrames
  }
}

public final class AudioRelayEngine: @unchecked Sendable {
  private static let channelCount: UInt32 = 2
  private static let maximumFramesPerSlice: UInt32 = 8192
  private static let ringCapacityFrames: UInt32 = 131_072

  private var sharedTransport: OpaquePointer?
  private var sharedBuffer: OpaquePointer?
  private var transportDeviceID: AudioObjectID?
  private var outputUnit: AudioUnit?
  private(set) public var isRunning = false

  public init() throws {}

  deinit {
    stop()
  }

  public func start(
    virtualDeviceID: AudioObjectID,
    destinationDeviceID: AudioObjectID,
    sampleRate: Double = 48_000,
    gain: Float
  ) throws {
    stop()

    do {
      try setNominalSampleRate(sampleRate, of: virtualDeviceID)

      guard
        let transport = SRSharedAudioTransportCreate(
          Self.ringCapacityFrames,
          Self.channelCount
        )
      else {
        throw AudioRelayEngineError.sharedTransport("unable to allocate shared memory")
      }
      sharedTransport = transport
      let buffer = SRSharedAudioTransportGetBuffer(transport)
      sharedBuffer = buffer
      SRSharedAudioBufferSetTargetGain(buffer, 0)
      SRSharedAudioBufferReset(buffer)

      guard let tokenPointer = SRSharedAudioTransportGetConfigurationToken(transport) else {
        throw AudioRelayEngineError.sharedTransport("unable to create driver token")
      }
      let token = String(cString: tokenPointer) as CFString
      try setSharedTransportToken(
        token,
        on: virtualDeviceID,
        operation: "Connect shared audio transport"
      )
      transportDeviceID = virtualDeviceID
      guard SRSharedAudioTransportUnlink(transport) else {
        throw AudioRelayEngineError.sharedTransport("unable to seal shared memory name")
      }

      let output = try makeHALAudioUnit()
      outputUnit = output
      try configureOutputUnit(
        output,
        deviceID: destinationDeviceID,
        sampleRate: sampleRate
      )

      try check(AudioUnitInitialize(output), "Initialize relay output")
      try check(AudioOutputUnitStart(output), "Start relay output")
      isRunning = true
      SRSharedAudioBufferSetTargetGain(buffer, gain)
    } catch {
      stop()
      throw error
    }
  }

  public func stop() {
    if isRunning, let sharedBuffer {
      SRSharedAudioBufferSetTargetGain(sharedBuffer, 0)
      Thread.sleep(forTimeInterval: 0.03)
    }
    if let outputUnit {
      AudioOutputUnitStop(outputUnit)
      AudioUnitUninitialize(outputUnit)
      AudioComponentInstanceDispose(outputUnit)
    }
    if let transportDeviceID {
      try? setSharedTransportToken(
        "" as CFString,
        on: transportDeviceID,
        operation: "Disconnect shared audio transport"
      )
    }
    outputUnit = nil
    transportDeviceID = nil
    sharedBuffer = nil
    if let sharedTransport {
      SRSharedAudioTransportDestroy(sharedTransport)
    }
    sharedTransport = nil
    isRunning = false
  }

  public func setGain(_ gain: Float) {
    guard let sharedBuffer else { return }
    SRSharedAudioBufferSetTargetGain(sharedBuffer, gain)
  }

  public func statistics() -> AudioRelayStatistics {
    guard let sharedBuffer else {
      return AudioRelayStatistics(
        capturedFrames: 0,
        requestedRenderFrames: 0,
        nonSilentCapturedSamples: 0,
        nonSilentRenderedSamples: 0,
        underflowFrames: 0
      )
    }
    let metrics = SRSharedAudioBufferGetMetrics(sharedBuffer)
    return AudioRelayStatistics(
      capturedFrames: metrics.capturedFrames,
      requestedRenderFrames: metrics.requestedRenderFrames,
      nonSilentCapturedSamples: metrics.nonSilentCapturedSamples,
      nonSilentRenderedSamples: metrics.nonSilentRenderedSamples,
      underflowFrames: metrics.underflowFrames
    )
  }

  fileprivate func render(
    bufferList: UnsafeMutablePointer<AudioBufferList>?,
    frameCount: UInt32
  ) -> OSStatus {
    guard let bufferList else { return kAudio_ParamError }
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    guard buffers.count == 1,
      buffers[0].mNumberChannels == Self.channelCount,
      let data = buffers[0].mData,
      buffers[0].mDataByteSize >= frameCount * Self.channelCount * UInt32(MemoryLayout<Float>.size)
    else {
      for index in buffers.indices {
        if let data = buffers[index].mData {
          memset(data, 0, Int(buffers[index].mDataByteSize))
        }
      }
      return kAudio_ParamError
    }

    guard let sharedBuffer else {
      memset(data, 0, Int(buffers[0].mDataByteSize))
      return noErr
    }
    let samples = data.assumingMemoryBound(to: Float.self)
    _ = SRSharedAudioBufferRead(sharedBuffer, samples, frameCount)
    return noErr
  }

  private func makeHALAudioUnit() throws -> AudioUnit {
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw AudioRelayEngineError.audioUnitComponentMissing
    }
    var unit: AudioUnit?
    try check(AudioComponentInstanceNew(component, &unit), "Create HAL audio unit")
    guard let unit else {
      throw AudioRelayEngineError.audioUnitComponentMissing
    }
    return unit
  }

  private func configureOutputUnit(
    _ unit: AudioUnit,
    deviceID: AudioObjectID,
    sampleRate: Double
  ) throws {
    var enabled: UInt32 = 1
    var disabled: UInt32 = 0
    try setProperty(
      unit,
      id: kAudioOutputUnitProperty_EnableIO,
      scope: kAudioUnitScope_Output,
      element: 0,
      value: &enabled,
      operation: "Enable physical-device output"
    )
    try setProperty(
      unit,
      id: kAudioOutputUnitProperty_EnableIO,
      scope: kAudioUnitScope_Input,
      element: 1,
      value: &disabled,
      operation: "Disable output unit input"
    )
    var deviceID = deviceID
    try setProperty(
      unit,
      id: kAudioOutputUnitProperty_CurrentDevice,
      scope: kAudioUnitScope_Global,
      element: 0,
      value: &deviceID,
      operation: "Select physical output device"
    )
    var format = relayFormat(sampleRate: sampleRate)
    try setProperty(
      unit,
      id: kAudioUnitProperty_StreamFormat,
      scope: kAudioUnitScope_Input,
      element: 0,
      value: &format,
      operation: "Set relay output format"
    )
    var callback = AURenderCallbackStruct(
      inputProc: speakerRouterOutputCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    try setProperty(
      unit,
      id: kAudioUnitProperty_SetRenderCallback,
      scope: kAudioUnitScope_Input,
      element: 0,
      value: &callback,
      operation: "Install relay output callback"
    )
    var maxFrames = Self.maximumFramesPerSlice
    try setProperty(
      unit,
      id: kAudioUnitProperty_MaximumFramesPerSlice,
      scope: kAudioUnitScope_Global,
      element: 0,
      value: &maxFrames,
      operation: "Set relay output frame capacity"
    )
  }

  private func relayFormat(sampleRate: Double) -> AudioStreamBasicDescription {
    let bytesPerFrame = Self.channelCount * UInt32(MemoryLayout<Float>.size)
    return AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: Self.channelCount,
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }

  private func setNominalSampleRate(
    _ sampleRate: Double,
    of deviceID: AudioObjectID
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = sampleRate
    let status = AudioObjectSetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<Double>.size),
      &sampleRate
    )
    try check(status, "Set virtual-device sample rate")
  }

  private func setSharedTransportToken(
    _ token: CFString,
    on deviceID: AudioObjectID,
    operation: String
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: AudioObjectPropertySelector(SRSharedAudioTransportPropertySelector),
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var token = token
    let status = withUnsafePointer(to: &token) { tokenPointer in
      AudioObjectSetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<CFString>.size),
        tokenPointer
      )
    }
    try check(status, operation)
  }

  private func setProperty<T: BitwiseCopyable>(
    _ unit: AudioUnit,
    id: AudioUnitPropertyID,
    scope: AudioUnitScope,
    element: AudioUnitElement,
    value: inout T,
    operation: String
  ) throws {
    let status = AudioUnitSetProperty(
      unit,
      id,
      scope,
      element,
      &value,
      UInt32(MemoryLayout<T>.size)
    )
    try check(status, operation)
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
      throw AudioRelayEngineError.operation(operation, status)
    }
  }
}

private func speakerRouterOutputCallback(
  _ refCon: UnsafeMutableRawPointer,
  _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  _ timestamp: UnsafePointer<AudioTimeStamp>,
  _ busNumber: UInt32,
  _ frameCount: UInt32,
  _ bufferList: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  let engine = Unmanaged<AudioRelayEngine>.fromOpaque(refCon).takeUnretainedValue()
  return engine.render(bufferList: bufferList, frameCount: frameCount)
}
