import AudioToolbox
import CoreAudio
import Foundation
import SpeakerRouterAudioSupport

public enum AudioRelayEngineError: Error, CustomStringConvertible, Sendable {
  case ringBufferAllocation
  case audioUnitComponentMissing
  case operation(String, OSStatus)
  case frameCountExceedsCapacity(UInt32)

  public var description: String {
    switch self {
    case .ringBufferAllocation:
      "Unable to allocate the real-time audio ring buffer"
    case .audioUnitComponentMissing:
      "The HAL output audio unit is unavailable"
    case .operation(let name, let status):
      "\(name) failed with Core Audio status \(status)"
    case .frameCountExceedsCapacity(let frameCount):
      "Audio callback requested \(frameCount) frames, above the relay capacity"
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
}

public final class AudioRelayEngine: @unchecked Sendable {
  private static let channelCount: UInt32 = 2
  private static let maximumFramesPerSlice: UInt32 = 8192
  private static let ringCapacityFrames: UInt32 = 131_072

  private let ringBuffer: OpaquePointer
  private var sourceDeviceID: AudioObjectID?
  private var sourceIOProcID: AudioDeviceIOProcID?
  private var outputUnit: AudioUnit?
  private(set) public var isRunning = false

  public init() throws {
    guard
      let ringBuffer = SRFloatRingBufferCreate(
        Self.ringCapacityFrames,
        Self.channelCount
      )
    else {
      throw AudioRelayEngineError.ringBufferAllocation
    }
    self.ringBuffer = ringBuffer
  }

  deinit {
    stop()
    SRFloatRingBufferDestroy(ringBuffer)
  }

  public func start(
    sourceDeviceID: AudioObjectID,
    destinationDeviceID: AudioObjectID,
    sampleRate: Double = 48_000,
    gain: Float
  ) throws {
    stop()
    SRFloatRingBufferSetTargetGain(ringBuffer, 0)
    SRFloatRingBufferReset(ringBuffer)

    do {
      try setNominalSampleRate(sampleRate, of: sourceDeviceID)

      let output = try makeHALAudioUnit()
      outputUnit = output
      try configureOutputUnit(
        output,
        deviceID: destinationDeviceID,
        sampleRate: sampleRate
      )

      try check(AudioUnitInitialize(output), "Initialize relay output")

      var sourceIOProcID: AudioDeviceIOProcID?
      try check(
        AudioDeviceCreateIOProcID(
          sourceDeviceID,
          speakerRouterSourceIOProc,
          Unmanaged.passUnretained(self).toOpaque(),
          &sourceIOProcID
        ),
        "Create virtual-device IO procedure"
      )
      guard let sourceIOProcID else {
        throw AudioRelayEngineError.operation(
          "Create virtual-device IO procedure",
          kAudioHardwareUnspecifiedError
        )
      }
      self.sourceDeviceID = sourceDeviceID
      self.sourceIOProcID = sourceIOProcID
      try check(
        AudioDeviceStart(sourceDeviceID, sourceIOProcID),
        "Start virtual-device IO procedure"
      )
      try check(AudioOutputUnitStart(output), "Start relay output")
      isRunning = true
      SRFloatRingBufferSetTargetGain(ringBuffer, gain)
    } catch {
      stop()
      throw error
    }
  }

  public func stop() {
    if isRunning {
      SRFloatRingBufferSetTargetGain(ringBuffer, 0)
      Thread.sleep(forTimeInterval: 0.03)
    }
    if let outputUnit {
      AudioOutputUnitStop(outputUnit)
      AudioUnitUninitialize(outputUnit)
      AudioComponentInstanceDispose(outputUnit)
    }
    if let sourceDeviceID, let sourceIOProcID {
      AudioDeviceStop(sourceDeviceID, sourceIOProcID)
      AudioDeviceDestroyIOProcID(sourceDeviceID, sourceIOProcID)
    }
    outputUnit = nil
    sourceDeviceID = nil
    sourceIOProcID = nil
    isRunning = false
  }

  public func setGain(_ gain: Float) {
    SRFloatRingBufferSetTargetGain(ringBuffer, gain)
  }

  public func statistics() -> AudioRelayStatistics {
    let metrics = SRFloatRingBufferGetMetrics(ringBuffer)
    return AudioRelayStatistics(
      capturedFrames: metrics.capturedFrames,
      requestedRenderFrames: metrics.requestedRenderFrames,
      nonSilentCapturedSamples: metrics.nonSilentCapturedSamples,
      nonSilentRenderedSamples: metrics.nonSilentRenderedSamples,
      underflowFrames: metrics.underflowFrames
    )
  }

  fileprivate func capture(
    inputData: UnsafePointer<AudioBufferList>
  ) -> OSStatus {
    let mutableInputData = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
    let buffers = UnsafeMutableAudioBufferListPointer(mutableInputData)
    guard buffers.count == 1,
      buffers[0].mNumberChannels == Self.channelCount,
      let data = buffers[0].mData
    else {
      return kAudio_ParamError
    }
    let bytesPerFrame = Self.channelCount * UInt32(MemoryLayout<Float>.size)
    guard buffers[0].mDataByteSize % bytesPerFrame == 0 else {
      return kAudio_ParamError
    }
    let frameCount = buffers[0].mDataByteSize / bytesPerFrame
    guard frameCount <= Self.maximumFramesPerSlice else {
      return kAudio_ParamError
    }
    let samples = data.assumingMemoryBound(to: Float.self)
    _ = SRFloatRingBufferWrite(ringBuffer, samples, frameCount)
    return noErr
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

    let samples = data.assumingMemoryBound(to: Float.self)
    _ = SRFloatRingBufferRead(ringBuffer, samples, frameCount)
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

private func speakerRouterSourceIOProc(
  _ deviceID: AudioObjectID,
  _ now: UnsafePointer<AudioTimeStamp>,
  _ inputData: UnsafePointer<AudioBufferList>,
  _ inputTime: UnsafePointer<AudioTimeStamp>,
  _ outputData: UnsafeMutablePointer<AudioBufferList>,
  _ outputTime: UnsafePointer<AudioTimeStamp>,
  _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let clientData else { return kAudio_ParamError }
  let engine = Unmanaged<AudioRelayEngine>.fromOpaque(clientData).takeUnretainedValue()
  return engine.capture(inputData: inputData)
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
