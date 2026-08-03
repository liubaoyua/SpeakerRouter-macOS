import SpeakerRouterAudioSupport
import Testing

@Suite("Shared audio transport")
struct SharedAudioTransportTests {
  @Test("Driver mapping and app mapping exchange stereo frames")
  func roundTripAcrossMappings() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8, 2))
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
    #expect(metrics.capturedFrames == 3)
    #expect(metrics.requestedRenderFrames == 3)
    #expect(metrics.nonSilentCapturedSamples == 6)
    #expect(metrics.nonSilentRenderedSamples == 6)
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
    let transport = try #require(SRSharedAudioTransportCreate(8, 2))
    defer { SRSharedAudioTransportDestroy(transport) }

    let token = try #require(SRSharedAudioTransportGetConfigurationToken(transport))
    var configuration = SRSharedAudioTransportConfiguration()
    #expect(SRSharedAudioTransportParseConfigurationToken(token, &configuration))

    let mapping = try #require(SRSharedAudioMappingOpen(&configuration))
    SRSharedAudioMappingDestroy(mapping)

    var disconnect = SRSharedAudioTransportConfiguration()
    #expect(SRSharedAudioTransportParseConfigurationToken("", &disconnect))
    #expect(SRSharedAudioTransportConfigurationIsDisconnect(&disconnect))
    #expect(!SRSharedAudioTransportParseConfigurationToken("invalid", &disconnect))
  }

  @Test("Underflow is padded with silence and counted")
  func underflow() throws {
    let transport = try #require(SRSharedAudioTransportCreate(8, 2))
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
    #expect(SRSharedAudioBufferGetMetrics(buffer).underflowFrames == 2)
  }

  @Test("Writer overrun preserves the newest complete frames")
  func writerOverrun() throws {
    let transport = try #require(SRSharedAudioTransportCreate(4, 2))
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
}
