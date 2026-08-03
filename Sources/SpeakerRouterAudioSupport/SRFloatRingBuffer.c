#include "SRFloatRingBuffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct SRFloatRingBuffer {
    uint32_t capacityFrames;
    uint32_t channelCount;
    float* samples;
    _Atomic uint64_t writePosition;
    _Atomic uint64_t readPosition;
    _Atomic uint64_t capturedFrames;
    _Atomic uint64_t requestedRenderFrames;
    _Atomic uint64_t nonSilentCapturedSamples;
    _Atomic uint64_t nonSilentRenderedSamples;
    _Atomic uint64_t underflowFrames;
    _Atomic float targetGain;
    float currentGain;
};

static float clampGain(float value) {
    if(value < 0.0f) {
        return 0.0f;
    }
    if(value > 1.0f) {
        return 1.0f;
    }
    return value;
}

SRFloatRingBuffer* SRFloatRingBufferCreate(
    uint32_t capacityFrames,
    uint32_t channelCount
) {
    if(capacityFrames == 0 || channelCount == 0) {
        return NULL;
    }

    SRFloatRingBuffer* buffer = calloc(1, sizeof(SRFloatRingBuffer));
    if(buffer == NULL) {
        return NULL;
    }

    size_t sampleCount = (size_t)capacityFrames * channelCount;
    buffer->samples = calloc(sampleCount, sizeof(float));
    if(buffer->samples == NULL) {
        free(buffer);
        return NULL;
    }

    buffer->capacityFrames = capacityFrames;
    buffer->channelCount = channelCount;
    atomic_init(&buffer->writePosition, 0);
    atomic_init(&buffer->readPosition, 0);
    atomic_init(&buffer->capturedFrames, 0);
    atomic_init(&buffer->requestedRenderFrames, 0);
    atomic_init(&buffer->nonSilentCapturedSamples, 0);
    atomic_init(&buffer->nonSilentRenderedSamples, 0);
    atomic_init(&buffer->underflowFrames, 0);
    atomic_init(&buffer->targetGain, 1.0f);
    buffer->currentGain = 1.0f;
    return buffer;
}

void SRFloatRingBufferDestroy(SRFloatRingBuffer* buffer) {
    if(buffer == NULL) {
        return;
    }
    free(buffer->samples);
    free(buffer);
}

void SRFloatRingBufferReset(SRFloatRingBuffer* buffer) {
    memset(
        buffer->samples,
        0,
        (size_t)buffer->capacityFrames * buffer->channelCount * sizeof(float)
    );
    atomic_store_explicit(&buffer->writePosition, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->readPosition, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->capturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->requestedRenderFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->nonSilentCapturedSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->nonSilentRenderedSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->underflowFrames, 0, memory_order_relaxed);
    buffer->currentGain = atomic_load_explicit(&buffer->targetGain, memory_order_relaxed);
}

uint32_t SRFloatRingBufferWrite(
    SRFloatRingBuffer* buffer,
    const float* interleavedSamples,
    uint32_t frameCount
) {
    if(frameCount == 0) {
        return 0;
    }

    if(frameCount > buffer->capacityFrames) {
        uint32_t framesToSkip = frameCount - buffer->capacityFrames;
        interleavedSamples += (size_t)framesToSkip * buffer->channelCount;
        frameCount = buffer->capacityFrames;
    }

    uint64_t writePosition = atomic_load_explicit(
        &buffer->writePosition,
        memory_order_relaxed
    );
    uint32_t startFrame = (uint32_t)(writePosition % buffer->capacityFrames);
    uint32_t firstFrames = buffer->capacityFrames - startFrame;
    if(firstFrames > frameCount) {
        firstFrames = frameCount;
    }

    memcpy(
        &buffer->samples[(size_t)startFrame * buffer->channelCount],
        interleavedSamples,
        (size_t)firstFrames * buffer->channelCount * sizeof(float)
    );
    if(firstFrames < frameCount) {
        memcpy(
            buffer->samples,
            &interleavedSamples[(size_t)firstFrames * buffer->channelCount],
            (size_t)(frameCount - firstFrames) * buffer->channelCount * sizeof(float)
        );
    }

    uint64_t nonSilentSamples = 0;
    size_t sampleCount = (size_t)frameCount * buffer->channelCount;
    for(size_t sample = 0; sample < sampleCount; ++sample) {
        float value = interleavedSamples[sample];
        if(value > 0.000001f || value < -0.000001f) {
            ++nonSilentSamples;
        }
    }
    atomic_fetch_add_explicit(
        &buffer->capturedFrames,
        frameCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &buffer->nonSilentCapturedSamples,
        nonSilentSamples,
        memory_order_relaxed
    );

    atomic_store_explicit(
        &buffer->writePosition,
        writePosition + frameCount,
        memory_order_release
    );
    return frameCount;
}

uint32_t SRFloatRingBufferRead(
    SRFloatRingBuffer* buffer,
    float* interleavedSamples,
    uint32_t frameCount
) {
    if(frameCount == 0) {
        return 0;
    }

    uint64_t writePosition = atomic_load_explicit(
        &buffer->writePosition,
        memory_order_acquire
    );
    uint64_t readPosition = atomic_load_explicit(
        &buffer->readPosition,
        memory_order_relaxed
    );
    if(writePosition < readPosition) {
        readPosition = writePosition;
    }

    uint64_t available = writePosition - readPosition;
    if(available > buffer->capacityFrames) {
        readPosition = writePosition - buffer->capacityFrames;
        available = buffer->capacityFrames;
    }

    uint32_t framesToRead = frameCount;
    if(available < framesToRead) {
        framesToRead = (uint32_t)available;
    }

    uint32_t startFrame = (uint32_t)(readPosition % buffer->capacityFrames);
    uint32_t firstFrames = buffer->capacityFrames - startFrame;
    if(firstFrames > framesToRead) {
        firstFrames = framesToRead;
    }

    memcpy(
        interleavedSamples,
        &buffer->samples[(size_t)startFrame * buffer->channelCount],
        (size_t)firstFrames * buffer->channelCount * sizeof(float)
    );
    if(firstFrames < framesToRead) {
        memcpy(
            &interleavedSamples[(size_t)firstFrames * buffer->channelCount],
            buffer->samples,
            (size_t)(framesToRead - firstFrames) * buffer->channelCount * sizeof(float)
        );
    }

    size_t samplesRead = (size_t)framesToRead * buffer->channelCount;
    size_t requestedSamples = (size_t)frameCount * buffer->channelCount;
    if(samplesRead < requestedSamples) {
        memset(
            &interleavedSamples[samplesRead],
            0,
            (requestedSamples - samplesRead) * sizeof(float)
        );
    }

    float targetGain = atomic_load_explicit(&buffer->targetGain, memory_order_relaxed);
    float gain = buffer->currentGain;
    float step = frameCount == 0 ? 0.0f : (targetGain - gain) / frameCount;
    for(uint32_t frame = 0; frame < frameCount; ++frame) {
        gain += step;
        size_t firstSample = (size_t)frame * buffer->channelCount;
        for(uint32_t channel = 0; channel < buffer->channelCount; ++channel) {
            interleavedSamples[firstSample + channel] *= gain;
        }
    }
    buffer->currentGain = targetGain;

    uint64_t nonSilentSamples = 0;
    for(size_t sample = 0; sample < requestedSamples; ++sample) {
        float value = interleavedSamples[sample];
        if(value > 0.000001f || value < -0.000001f) {
            ++nonSilentSamples;
        }
    }
    atomic_fetch_add_explicit(
        &buffer->requestedRenderFrames,
        frameCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &buffer->nonSilentRenderedSamples,
        nonSilentSamples,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &buffer->underflowFrames,
        frameCount - framesToRead,
        memory_order_relaxed
    );

    atomic_store_explicit(
        &buffer->readPosition,
        readPosition + framesToRead,
        memory_order_relaxed
    );
    return framesToRead;
}

void SRFloatRingBufferSetTargetGain(
    SRFloatRingBuffer* buffer,
    float scalarGain
) {
    atomic_store_explicit(
        &buffer->targetGain,
        clampGain(scalarGain),
        memory_order_relaxed
    );
}

float SRFloatRingBufferGetTargetGain(const SRFloatRingBuffer* buffer) {
    return atomic_load_explicit(&buffer->targetGain, memory_order_relaxed);
}

uint64_t SRFloatRingBufferAvailableFrames(const SRFloatRingBuffer* buffer) {
    uint64_t writePosition = atomic_load_explicit(
        &buffer->writePosition,
        memory_order_acquire
    );
    uint64_t readPosition = atomic_load_explicit(
        &buffer->readPosition,
        memory_order_relaxed
    );
    if(writePosition <= readPosition) {
        return 0;
    }
    uint64_t available = writePosition - readPosition;
    return available > buffer->capacityFrames ? buffer->capacityFrames : available;
}

SRFloatRingBufferMetrics SRFloatRingBufferGetMetrics(
    const SRFloatRingBuffer* buffer
) {
    SRFloatRingBufferMetrics metrics = {
        .capturedFrames = atomic_load_explicit(
            &buffer->capturedFrames,
            memory_order_relaxed
        ),
        .requestedRenderFrames = atomic_load_explicit(
            &buffer->requestedRenderFrames,
            memory_order_relaxed
        ),
        .nonSilentCapturedSamples = atomic_load_explicit(
            &buffer->nonSilentCapturedSamples,
            memory_order_relaxed
        ),
        .nonSilentRenderedSamples = atomic_load_explicit(
            &buffer->nonSilentRenderedSamples,
            memory_order_relaxed
        ),
        .underflowFrames = atomic_load_explicit(
            &buffer->underflowFrames,
            memory_order_relaxed
        ),
    };
    return metrics;
}
