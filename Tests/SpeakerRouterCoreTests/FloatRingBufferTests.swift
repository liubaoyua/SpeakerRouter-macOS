import SpeakerRouterAudioSupport
import Testing
@testable import SpeakerRouterCore

@Suite("Float ring buffer")
struct FloatRingBufferTests {
  @Test("Stereo frames round trip in order")
  func roundTrip() throws {
    let ring = try #require(SRFloatRingBufferCreate(8, 2))
    defer { SRFloatRingBufferDestroy(ring) }

    let input: [Float] = [1, -1, 2, -2, 3, -3]
    let written = input.withUnsafeBufferPointer {
      SRFloatRingBufferWrite(ring, $0.baseAddress!, 3)
    }
    var output = [Float](repeating: 0, count: 6)
    let read = output.withUnsafeMutableBufferPointer {
      SRFloatRingBufferRead(ring, $0.baseAddress!, 3)
    }

    #expect(written == 3)
    #expect(read == 3)
    #expect(output == input)
    #expect(SRFloatRingBufferAvailableFrames(ring) == 0)
    let metrics = SRFloatRingBufferGetMetrics(ring)
    #expect(metrics.capturedFrames == 3)
    #expect(metrics.requestedRenderFrames == 3)
    #expect(metrics.nonSilentCapturedSamples == 6)
    #expect(metrics.nonSilentRenderedSamples == 6)
    #expect(metrics.underflowFrames == 0)
  }

  @Test("Underflow is padded with silence")
  func underflow() throws {
    let ring = try #require(SRFloatRingBufferCreate(8, 2))
    defer { SRFloatRingBufferDestroy(ring) }

    let input: [Float] = [0.5, -0.5]
    input.withUnsafeBufferPointer {
      _ = SRFloatRingBufferWrite(ring, $0.baseAddress!, 1)
    }
    var output = [Float](repeating: 9, count: 6)
    let read = output.withUnsafeMutableBufferPointer {
      SRFloatRingBufferRead(ring, $0.baseAddress!, 3)
    }

    #expect(read == 1)
    #expect(output == [0.5, -0.5, 0, 0, 0, 0])
    let metrics = SRFloatRingBufferGetMetrics(ring)
    #expect(metrics.capturedFrames == 1)
    #expect(metrics.requestedRenderFrames == 3)
    #expect(metrics.nonSilentCapturedSamples == 2)
    #expect(metrics.nonSilentRenderedSamples == 2)
    #expect(metrics.underflowFrames == 2)
  }

  @Test("Gain is clamped and smoothly reaches the target")
  func gain() throws {
    let ring = try #require(SRFloatRingBufferCreate(8, 2))
    defer { SRFloatRingBufferDestroy(ring) }

    SRFloatRingBufferSetTargetGain(ring, 2)
    #expect(SRFloatRingBufferGetTargetGain(ring) == 1)
    SRFloatRingBufferSetTargetGain(ring, 0)

    let input = [Float](repeating: 1, count: 8)
    input.withUnsafeBufferPointer {
      _ = SRFloatRingBufferWrite(ring, $0.baseAddress!, 4)
    }
    var output = [Float](repeating: 0, count: 8)
    output.withUnsafeMutableBufferPointer {
      _ = SRFloatRingBufferRead(ring, $0.baseAddress!, 4)
    }

    #expect(output[0] == 0.75)
    #expect(output[2] == 0.5)
    #expect(output[4] == 0.25)
    #expect(output[6] == 0)
  }

  @Test("Relay health remains valid while the virtual output is idle")
  func relayHealth() {
    let baseline = AudioRelayStatistics(
      capturedFrames: 100,
      requestedRenderFrames: 100,
      nonSilentCapturedSamples: 0,
      nonSilentRenderedSamples: 0,
      underflowFrames: 0
    )
    let healthy = AudioRelayStatistics(
      capturedFrames: 200,
      requestedRenderFrames: 200,
      nonSilentCapturedSamples: 0,
      nonSilentRenderedSamples: 0,
      underflowFrames: 0
    )
    let idleSource = AudioRelayStatistics(
      capturedFrames: 100,
      requestedRenderFrames: 200,
      nonSilentCapturedSamples: 0,
      nonSilentRenderedSamples: 0,
      underflowFrames: 0
    )
    let stalledRender = AudioRelayStatistics(
      capturedFrames: 200,
      requestedRenderFrames: 100,
      nonSilentCapturedSamples: 0,
      nonSilentRenderedSamples: 0,
      underflowFrames: 0
    )

    #expect(healthy.renderCallbackAdvanced(since: baseline))
    #expect(idleSource.renderCallbackAdvanced(since: baseline))
    #expect(!stalledRender.renderCallbackAdvanced(since: baseline))
  }
}
