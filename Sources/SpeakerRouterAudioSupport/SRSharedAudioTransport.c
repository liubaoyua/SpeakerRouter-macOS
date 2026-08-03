#include "SRSharedAudioTransport.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define SRSharedAudioTransportMagic 0x53524155u

struct SRSharedAudioBuffer {
    uint32_t magic;
    uint32_t protocolVersion;
    uint32_t headerSize;
    uint32_t mappingSize;
    uint32_t capacityFrames;
    uint32_t channelCount;
    uint32_t reserved0;
    uint32_t reserved1;
    _Atomic uint64_t writePosition;
    _Atomic uint64_t readPosition;
    _Atomic uint64_t requestedRenderFrames;
    _Atomic float targetGain;
    float currentGain;
    float samples[];
};

struct SRSharedAudioTransport {
    int descriptor;
    size_t mappingSize;
    bool nameWasUnlinked;
    SRSharedAudioTransportConfiguration configuration;
    char configurationToken[SRSharedAudioTransportTokenCapacity];
    SRSharedAudioBuffer* buffer;
};

struct SRSharedAudioMapping {
    size_t mappingSize;
    SRSharedAudioBuffer* buffer;
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

static bool calculateMappingSize(
    uint32_t capacityFrames,
    uint32_t channelCount,
    size_t* mappingSize
) {
    if(capacityFrames == 0 || channelCount == 0 || mappingSize == NULL) {
        return false;
    }
    size_t sampleCount = (size_t)capacityFrames * channelCount;
    if(sampleCount / channelCount != capacityFrames ||
        sampleCount > (SIZE_MAX - sizeof(SRSharedAudioBuffer)) / sizeof(float)) {
        return false;
    }
    *mappingSize = sizeof(SRSharedAudioBuffer) + sampleCount * sizeof(float);
    return *mappingSize <= UINT32_MAX;
}

static bool bufferHeaderIsValid(
    const SRSharedAudioBuffer* buffer,
    size_t mappedSize
) {
    if(buffer == NULL ||
        buffer->magic != SRSharedAudioTransportMagic ||
        buffer->protocolVersion != SRSharedAudioTransportProtocolVersion ||
        buffer->headerSize != sizeof(SRSharedAudioBuffer) ||
        buffer->mappingSize != mappedSize) {
        return false;
    }
    size_t expectedSize = 0;
    return calculateMappingSize(
        buffer->capacityFrames,
        buffer->channelCount,
        &expectedSize
    ) && expectedSize == mappedSize;
}

SRSharedAudioTransport* SRSharedAudioTransportCreate(
    uint32_t capacityFrames,
    uint32_t channelCount
) {
    size_t mappingSize = 0;
    if(!calculateMappingSize(capacityFrames, channelCount, &mappingSize)) {
        return NULL;
    }

    SRSharedAudioTransport* transport = calloc(1, sizeof(SRSharedAudioTransport));
    if(transport == NULL) {
        return NULL;
    }
    transport->descriptor = -1;

    // Darwin limits POSIX shared-memory names to 31 bytes including the leading slash.
    // A short prefix plus 96 random bits stays below that limit while remaining unguessable.
    uint32_t randomParts[3] = {0};
    arc4random_buf(randomParts, sizeof(randomParts));
    int nameLength = snprintf(
        transport->configuration.sharedMemoryName,
        sizeof(transport->configuration.sharedMemoryName),
        "/SR-%08x%08x%08x",
        randomParts[0],
        randomParts[1],
        randomParts[2]
    );
    if(nameLength <= 0 ||
        (size_t)nameLength >= sizeof(transport->configuration.sharedMemoryName)) {
        free(transport);
        return NULL;
    }

    int descriptor = shm_open(
        transport->configuration.sharedMemoryName,
        O_CREAT | O_EXCL | O_RDWR,
        0666
    );
    if(descriptor < 0) {
        free(transport);
        return NULL;
    }
    transport->descriptor = descriptor;

    // The driver host runs as _coreaudiod, so it needs a short window in which it can open the
    // unguessable name. The app unlinks the name immediately after the driver's mapping succeeds.
    if(ftruncate(descriptor, (off_t)mappingSize) != 0) {
        SRSharedAudioTransportDestroy(transport);
        return NULL;
    }

    void* memory = mmap(
        NULL,
        mappingSize,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptor,
        0
    );
    if(memory == MAP_FAILED) {
        SRSharedAudioTransportDestroy(transport);
        return NULL;
    }

    transport->mappingSize = mappingSize;
    transport->buffer = memory;
    transport->configuration.protocolVersion = SRSharedAudioTransportProtocolVersion;
    transport->configuration.mappingSize = (uint32_t)mappingSize;
    int tokenLength = snprintf(
        transport->configurationToken,
        sizeof(transport->configurationToken),
        "SR%u|%u|%s",
        transport->configuration.protocolVersion,
        transport->configuration.mappingSize,
        transport->configuration.sharedMemoryName
    );
    if(tokenLength <= 0 ||
        (size_t)tokenLength >= sizeof(transport->configurationToken)) {
        SRSharedAudioTransportDestroy(transport);
        return NULL;
    }

    memset(memory, 0, mappingSize);
    transport->buffer->magic = SRSharedAudioTransportMagic;
    transport->buffer->protocolVersion = SRSharedAudioTransportProtocolVersion;
    transport->buffer->headerSize = sizeof(SRSharedAudioBuffer);
    transport->buffer->mappingSize = (uint32_t)mappingSize;
    transport->buffer->capacityFrames = capacityFrames;
    transport->buffer->channelCount = channelCount;
    atomic_init(&transport->buffer->writePosition, 0);
    atomic_init(&transport->buffer->readPosition, 0);
    atomic_init(&transport->buffer->requestedRenderFrames, 0);
    atomic_init(&transport->buffer->targetGain, 1.0f);
    transport->buffer->currentGain = 1.0f;
    return transport;
}

void SRSharedAudioTransportDestroy(SRSharedAudioTransport* transport) {
    if(transport == NULL) {
        return;
    }
    if(!transport->nameWasUnlinked &&
        transport->configuration.sharedMemoryName[0] != '\0') {
        shm_unlink(transport->configuration.sharedMemoryName);
    }
    if(transport->buffer != NULL && transport->mappingSize > 0) {
        munmap(transport->buffer, transport->mappingSize);
    }
    if(transport->descriptor >= 0) {
        close(transport->descriptor);
    }
    free(transport);
}

bool SRSharedAudioTransportCopyConfiguration(
    const SRSharedAudioTransport* transport,
    SRSharedAudioTransportConfiguration* configuration
) {
    if(transport == NULL || configuration == NULL || transport->buffer == NULL) {
        return false;
    }
    *configuration = transport->configuration;
    return true;
}

const char* SRSharedAudioTransportGetConfigurationToken(
    const SRSharedAudioTransport* transport
) {
    if(transport == NULL || transport->configurationToken[0] == '\0') {
        return NULL;
    }
    return transport->configurationToken;
}

bool SRSharedAudioTransportUnlink(SRSharedAudioTransport* transport) {
    if(transport == NULL) {
        return false;
    }
    if(transport->nameWasUnlinked) {
        return true;
    }
    if(shm_unlink(transport->configuration.sharedMemoryName) != 0) {
        return false;
    }
    transport->nameWasUnlinked = true;
    return true;
}

SRSharedAudioBuffer* SRSharedAudioTransportGetBuffer(
    SRSharedAudioTransport* transport
) {
    return transport->buffer;
}

SRSharedAudioMapping* SRSharedAudioMappingOpen(
    const SRSharedAudioTransportConfiguration* configuration
) {
    if(configuration == NULL ||
        configuration->protocolVersion != SRSharedAudioTransportProtocolVersion ||
        configuration->mappingSize < sizeof(SRSharedAudioBuffer) ||
        configuration->sharedMemoryName[0] != '/' ||
        strncmp(configuration->sharedMemoryName, "/SR-", 4) != 0 ||
        memchr(
            configuration->sharedMemoryName,
            '\0',
            sizeof(configuration->sharedMemoryName)
        ) == NULL) {
        return NULL;
    }

    int descriptor = shm_open(configuration->sharedMemoryName, O_RDWR, 0);
    if(descriptor < 0) {
        return NULL;
    }
    struct stat status = {0};
    // Darwin rounds POSIX shared-memory objects up to its VM allocation granularity.
    if(fstat(descriptor, &status) != 0 ||
        status.st_size < (off_t)configuration->mappingSize) {
        close(descriptor);
        return NULL;
    }

    void* memory = mmap(
        NULL,
        configuration->mappingSize,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptor,
        0
    );
    close(descriptor);
    if(memory == MAP_FAILED) {
        return NULL;
    }
    if(!bufferHeaderIsValid(memory, configuration->mappingSize)) {
        munmap(memory, configuration->mappingSize);
        return NULL;
    }

    SRSharedAudioMapping* mapping = calloc(1, sizeof(SRSharedAudioMapping));
    if(mapping == NULL) {
        munmap(memory, configuration->mappingSize);
        return NULL;
    }
    mapping->mappingSize = configuration->mappingSize;
    mapping->buffer = memory;
    return mapping;
}

void SRSharedAudioMappingDestroy(SRSharedAudioMapping* mapping) {
    if(mapping == NULL) {
        return;
    }
    if(mapping->buffer != NULL && mapping->mappingSize > 0) {
        munmap(mapping->buffer, mapping->mappingSize);
    }
    free(mapping);
}

SRSharedAudioBuffer* SRSharedAudioMappingGetBuffer(SRSharedAudioMapping* mapping) {
    return mapping->buffer;
}

void SRSharedAudioTransportMakeDisconnectConfiguration(
    SRSharedAudioTransportConfiguration* configuration
) {
    memset(configuration, 0, sizeof(*configuration));
    configuration->protocolVersion = SRSharedAudioTransportProtocolVersion;
}

bool SRSharedAudioTransportConfigurationIsDisconnect(
    const SRSharedAudioTransportConfiguration* configuration
) {
    return configuration != NULL &&
        configuration->protocolVersion == SRSharedAudioTransportProtocolVersion &&
        configuration->mappingSize == 0 &&
        configuration->sharedMemoryName[0] == '\0';
}

bool SRSharedAudioTransportParseConfigurationToken(
    const char* token,
    SRSharedAudioTransportConfiguration* configuration
) {
    if(token == NULL || configuration == NULL) {
        return false;
    }
    if(token[0] == '\0') {
        SRSharedAudioTransportMakeDisconnectConfiguration(configuration);
        return true;
    }

    char prefix[16] = {0};
    int prefixLength = snprintf(
        prefix,
        sizeof(prefix),
        "SR%u|",
        SRSharedAudioTransportProtocolVersion
    );
    if(prefixLength <= 0 || (size_t)prefixLength >= sizeof(prefix) ||
        strncmp(token, prefix, (size_t)prefixLength) != 0) {
        return false;
    }
    const char* sizeStart = token + prefixLength;
    char* sizeEnd = NULL;
    unsigned long mappingSize = strtoul(sizeStart, &sizeEnd, 10);
    if(sizeEnd == sizeStart || sizeEnd == NULL || *sizeEnd != '|' ||
        mappingSize == 0 || mappingSize > UINT32_MAX) {
        return false;
    }
    const char* name = sizeEnd + 1;
    size_t nameLength = strlen(name);
    if(nameLength < 4 || nameLength >= SRSharedAudioTransportNameCapacity ||
        strncmp(name, "/SR-", 4) != 0) {
        return false;
    }

    memset(configuration, 0, sizeof(*configuration));
    configuration->protocolVersion = SRSharedAudioTransportProtocolVersion;
    configuration->mappingSize = (uint32_t)mappingSize;
    memcpy(configuration->sharedMemoryName, name, nameLength + 1);
    return true;
}

void SRSharedAudioBufferReset(SRSharedAudioBuffer* buffer) {
    memset(
        buffer->samples,
        0,
        (size_t)buffer->capacityFrames * buffer->channelCount * sizeof(float)
    );
    atomic_store_explicit(&buffer->writePosition, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->readPosition, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->requestedRenderFrames, 0, memory_order_relaxed);
    buffer->currentGain = atomic_load_explicit(&buffer->targetGain, memory_order_relaxed);
}

uint32_t SRSharedAudioBufferWrite(
    SRSharedAudioBuffer* buffer,
    const float* interleavedSamples,
    uint32_t frameCount
) {
    if(buffer == NULL || interleavedSamples == NULL || frameCount == 0) {
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

    atomic_store_explicit(
        &buffer->writePosition,
        writePosition + frameCount,
        memory_order_release
    );
    return frameCount;
}

uint32_t SRSharedAudioBufferRead(
    SRSharedAudioBuffer* buffer,
    float* interleavedSamples,
    uint32_t frameCount
) {
    if(buffer == NULL || interleavedSamples == NULL || frameCount == 0) {
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
    float step = (targetGain - gain) / frameCount;
    for(uint32_t frame = 0; frame < frameCount; ++frame) {
        gain += step;
        size_t firstSample = (size_t)frame * buffer->channelCount;
        for(uint32_t channel = 0; channel < buffer->channelCount; ++channel) {
            interleavedSamples[firstSample + channel] *= gain;
        }
    }
    buffer->currentGain = targetGain;

    atomic_fetch_add_explicit(
        &buffer->requestedRenderFrames,
        frameCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &buffer->readPosition,
        readPosition + framesToRead,
        memory_order_relaxed
    );
    return framesToRead;
}

void SRSharedAudioBufferSetTargetGain(
    SRSharedAudioBuffer* buffer,
    float scalarGain
) {
    atomic_store_explicit(
        &buffer->targetGain,
        clampGain(scalarGain),
        memory_order_relaxed
    );
}

float SRSharedAudioBufferGetTargetGain(const SRSharedAudioBuffer* buffer) {
    return atomic_load_explicit(&buffer->targetGain, memory_order_relaxed);
}

uint64_t SRSharedAudioBufferAvailableFrames(const SRSharedAudioBuffer* buffer) {
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

SRSharedAudioMetrics SRSharedAudioBufferGetMetrics(
    const SRSharedAudioBuffer* buffer
) {
    SRSharedAudioMetrics metrics = {
        .requestedRenderFrames = atomic_load_explicit(
            &buffer->requestedRenderFrames,
            memory_order_relaxed
        ),
    };
    return metrics;
}
