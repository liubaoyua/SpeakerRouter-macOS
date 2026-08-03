#ifndef SRFloatRingBuffer_h
#define SRFloatRingBuffer_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SRFloatRingBuffer SRFloatRingBuffer;

typedef struct SRFloatRingBufferMetrics {
    uint64_t capturedFrames;
    uint64_t requestedRenderFrames;
    uint64_t nonSilentCapturedSamples;
    uint64_t nonSilentRenderedSamples;
    uint64_t underflowFrames;
} SRFloatRingBufferMetrics;

SRFloatRingBuffer* _Nullable SRFloatRingBufferCreate(
    uint32_t capacityFrames,
    uint32_t channelCount
);
void SRFloatRingBufferDestroy(SRFloatRingBuffer* _Nullable buffer);
void SRFloatRingBufferReset(SRFloatRingBuffer* _Nonnull buffer);

uint32_t SRFloatRingBufferWrite(
    SRFloatRingBuffer* _Nonnull buffer,
    const float* _Nonnull interleavedSamples,
    uint32_t frameCount
);

uint32_t SRFloatRingBufferRead(
    SRFloatRingBuffer* _Nonnull buffer,
    float* _Nonnull interleavedSamples,
    uint32_t frameCount
);

void SRFloatRingBufferSetTargetGain(
    SRFloatRingBuffer* _Nonnull buffer,
    float scalarGain
);

float SRFloatRingBufferGetTargetGain(
    const SRFloatRingBuffer* _Nonnull buffer
);

uint64_t SRFloatRingBufferAvailableFrames(
    const SRFloatRingBuffer* _Nonnull buffer
);

SRFloatRingBufferMetrics SRFloatRingBufferGetMetrics(
    const SRFloatRingBuffer* _Nonnull buffer
);

#ifdef __cplusplus
}
#endif

#endif
