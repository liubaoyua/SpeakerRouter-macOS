import CoreAudio
import SpeakerRouterAudioSupport
import Testing
@testable import SpeakerRouterCore

@Suite("Shared audio transport")
struct SharedAudioTransportTests {
  @Test("Driver mapping and app mapping exchange stereo frames")
  func roundTripAcrossMappings() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8, 2, 0))
    defer { SRSharedAudioTransportDestroy(transport) }

    var configuration = SRSharedAudioTransportConfiguration()
    #expect(SRSharedAudioTransportCopyConfiguration(transport, &configuration))
    let driverMapping = try #require(SRSharedAudioMappingOpen(&configuration))
    defer { SRSharedAudioMappingDestroy(driverMapping) }

    #expect(SRSharedAudioTransportUnlink(transport))
    #expect(SRSharedAudioMappingOpen(&configuration) == nil)

    let driverBuffer = SRSharedAudioMappingGetBuffer(driverMapping)
    let appBuffer = SRSharedAudioTransportGetBuffer(transport)
    let input: [Float] = [0.25, -0.25, 0.5, -0.5, 0.75, -0.75]
    let written = input.withUnsafeBufferPointer {
      SRSharedAudioBufferWrite(driverBuffer, $0.baseAddress!, 3)
    }
    var output = [Float](repeating: 0, count: input.count)
    let read = output.withUnsafeMutableBufferPointer {
      SRSharedAudioBufferRead(appBuffer, $0.baseAddress!, 3)
    }

    #expect(written == 3)
    #expect(read == 3)
    #expect(output == input)
    let metrics = SRSharedAudioBufferGetMetrics(appBuffer)
    #expect(metrics.writtenFrames == 3)
    #expect(metrics.requestedRenderFrames == 3)
  }

  @Test("Disconnect configuration cannot be mapped")
  func disconnectConfiguration() {
    var configuration = SRSharedAudioTransportConfiguration()
    SRSharedAudioTransportMakeDisconnectConfiguration(&configuration)

    #expect(SRSharedAudioTransportConfigurationIsDisconnect(&configuration))
    #expect(SRSharedAudioMappingOpen(&configuration) == nil)
  }

  @Test("Configuration token round-trips through the remote-driver wire format")
  func configurationTokenRoundTrip() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8, 2, 2468))
    defer { SRSharedAudioTransportDestroy(transport) }

    let token = try #require(SRSharedAudioTransportGetConfigurationToken(transport))
    var configuration = SRSharedAudioTransportConfiguration()
    #expect(SRSharedAudioTransportParseConfigurationToken(token, &configuration))
    #expect(configuration.outputLatencyFrames == 2468)

    let mapping = try #require(SRSharedAudioMappingOpen(&configuration))
    SRSharedAudioMappingDestroy(mapping)

    var disconnect = SRSharedAudioTransportConfiguration()
    #expect(SRSharedAudioTransportParseConfigurationToken("", &disconnect))
    #expect(SRSharedAudioTransportConfigurationIsDisconnect(&disconnect))
    #expect(!SRSharedAudioTransportParseConfigurationToken("invalid", &disconnect))
  }

  @Test("An obsolete protocol token is rejected")
  func obsoleteProtocolToken() {
    var configuration = SRSharedAudioTransportConfiguration()
    let accepted = "SR2|4096|/SR-000000000000000000000000".withCString {
      SRSharedAudioTransportParseConfigurationToken($0, &configuration)
    }
    #expect(!accepted)
  }

  @Test("A rejected transport protocol produces an actionable error")
  func rejectedProtocolError() {
    let error = AudioRelayEngineError.operation(
      "Connect shared audio transport",
      kAudioHardwareIllegalOperationError
    )
    #expect(error.description.contains("update or reinstall the driver"))
  }

  @Test("Physical latency is converted into virtual-device frames")
  func outputLatencyConversion() {
    #expect(
      AudioRelayEngine.convertOutputLatencyFrames(
        physicalFrames: 441,
        physicalSampleRate: 44_100,
        relaySampleRate: 48_000,
        bufferedFrames: 1024
      ) == 1504
    )
  }

  @Test("Underflow is padded with silence")
  func underflow() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8, 2, 0))
    defer { SRSharedAudioTransportDestroy(transport) }
    let buffer = SRSharedAudioTransportGetBuffer(transport)
    let input: [Float] = [0.5, -0.5]
    input.withUnsafeBufferPointer {
      _ = SRSharedAudioBufferWrite(buffer, $0.baseAddress!, 1)
    }
    var output = [Float](repeating: 9, count: 6)
    let read = output.withUnsafeMutableBufferPointer {
      SRSharedAudioBufferRead(buffer, $0.baseAddress!, 3)
    }

    #expect(read == 1)
    #expect(output == [0.5, -0.5, 0, 0, 0, 0])
  }

  @Test("Writer overrun preserves the newest complete frames")
  func writerOverrun() throws {
    let transport = try #require(SRSharedAudioTransportCreate(4, 2, 0))
    defer { SRSharedAudioTransportDestroy(transport) }
    let buffer = SRSharedAudioTransportGetBuffer(transport)
    let input: [Float] = [
      1, -1, 2, -2, 3, -3,
      4, -4, 5, -5, 6, -6,
    ]
    input.withUnsafeBufferPointer { samples in
      _ = SRSharedAudioBufferWrite(buffer, samples.baseAddress!, 3)
      _ = SRSharedAudioBufferWrite(buffer, samples.baseAddress! + 6, 3)
    }
    var output = [Float](repeating: 0, count: 8)
    let read = output.withUnsafeMutableBufferPointer {
      SRSharedAudioBufferRead(buffer, $0.baseAddress!, 4)
    }

    #expect(read == 4)
    #expect(output == [3, -3, 4, -4, 5, -5, 6, -6])
  }

  @Test("Drift compensation discards stale multi-second backlog")
  func driftCompensationBoundsLatency() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8192, 2, 0))
    defer { SRSharedAudioTransportDestroy(transport) }
    let buffer = SRSharedAudioTransportGetBuffer(transport)
    let input = (0..<5000).flatMap { frame in
      [Float(frame), -Float(frame)]
    }
    input.withUnsafeBufferPointer {
      _ = SRSharedAudioBufferWrite(buffer, $0.baseAddress!, 5000)
    }

    var output = [Float](repeating: 0, count: 8)
    let consumed = output.withUnsafeMutableBufferPointer {
      SRSharedAudioBufferReadWithDriftCompensation(buffer, $0.baseAddress!, 4)
    }

    #expect(consumed == 4)
    #expect(output == [3976, -3976, 3977, -3977, 3978, -3978, 3979, -3979])
    #expect(SRSharedAudioBufferAvailableFrames(buffer) == 1020)
  }

  @Test("Drift compensation tracks a consistently faster producer")
  func fasterProducerClock() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8192, 2, 0))
    defer { SRSharedAudioTransportDestroy(transport) }
    let buffer = SRSharedAudioTransportGetBuffer(transport)
    let input = [Float](repeating: 0.25, count: 481 * 2)
    var output = [Float](repeating: 0, count: 480 * 2)

    for _ in 0..<5000 {
      input.withUnsafeBufferPointer {
        _ = SRSharedAudioBufferWrite(buffer, $0.baseAddress!, 481)
      }
      output.withUnsafeMutableBufferPointer {
        _ = SRSharedAudioBufferReadWithDriftCompensation(buffer, $0.baseAddress!, 480)
      }
    }

    #expect(SRSharedAudioBufferAvailableFrames(buffer) < 1600)
    #expect(output.allSatisfy { $0 == 0.25 })
  }

  @Test("A large producer batch plays through smaller output callbacks without gaps")
  func batchedProducer() throws {
    let transport = try #require(SRSharedAudioTransportCreate(131_072, 2, 0))
    defer { SRSharedAudioTransportDestroy(transport) }
    let buffer = SRSharedAudioTransportGetBuffer(transport)
    let input = (0..<4096).flatMap { frame in
      [Float(frame + 1), -Float(frame + 1)]
    }
    var output = [Float](repeating: 0, count: 512 * 2)

    for _ in 0..<4 {
      input.withUnsafeBufferPointer {
        _ = SRSharedAudioBufferWrite(buffer, $0.baseAddress!, 4096)
      }
      for offset in stride(from: 0, to: input.count, by: output.count) {
        let consumed = output.withUnsafeMutableBufferPointer {
          SRSharedAudioBufferReadWithDriftCompensation(buffer, $0.baseAddress!, 512)
        }
        #expect(consumed == 512)
        #expect(output.elementsEqual(input[offset..<(offset + output.count)]))
      }
    }
  }

  @Test("Gain is clamped and smoothly reaches the target")
  func gain() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8, 2, 0))
    defer { SRSharedAudioTransportDestroy(transport) }
    let buffer = SRSharedAudioTransportGetBuffer(transport)

    SRSharedAudioBufferSetTargetGain(buffer, 2)
    #expect(SRSharedAudioBufferGetTargetGain(buffer) == 1)
    SRSharedAudioBufferSetTargetGain(buffer, 0)

    let input = [Float](repeating: 1, count: 8)
    input.withUnsafeBufferPointer {
      _ = SRSharedAudioBufferWrite(buffer, $0.baseAddress!, 4)
    }
    var output = [Float](repeating: 0, count: 8)
    output.withUnsafeMutableBufferPointer {
      _ = SRSharedAudioBufferRead(buffer, $0.baseAddress!, 4)
    }

    #expect(output[0] == 0.75)
    #expect(output[2] == 0.5)
    #expect(output[4] == 0.25)
    #expect(output[6] == 0)
  }

  @Test("Relay health depends only on the physical render callback")
  func relayHealth() {
    let baseline = AudioRelayStatistics(writtenFrames: 10, requestedRenderFrames: 100)
    let healthy = AudioRelayStatistics(writtenFrames: 10, requestedRenderFrames: 200)
    let stalled = AudioRelayStatistics(writtenFrames: 20, requestedRenderFrames: 100)

    #expect(healthy.renderCallbackAdvanced(since: baseline))
    #expect(!stalled.renderCallbackAdvanced(since: baseline))
  }

  @Test("Recent audio activity follows producer progress, not the always-running renderer")
  func recentAudioActivity() {
    var tracker = RecentAudioActivityTracker(maximumIdleInterval: 2)

    tracker.observe(writtenFrames: 100, at: 10)
    #expect(!tracker.hasRecentActivity(at: 10))

    tracker.observe(writtenFrames: 200, at: 11)
    #expect(tracker.hasRecentActivity(at: 12.9))
    #expect(!tracker.hasRecentActivity(at: 13.1))

    tracker.observe(writtenFrames: 0, at: 14)
    #expect(!tracker.hasRecentActivity(at: 14))
  }
}
