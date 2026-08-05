#ifndef SRSharedAudioTransport_h
#define SRSharedAudioTransport_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SRSharedAudioTransportPropertySelector 0x5352736du
#define SRSharedAudioTransportProtocolVersion 3u
#define SRSharedAudioTransportNameCapacity 96u
#define SRSharedAudioTransportTokenCapacity 160u

typedef struct SRSharedAudioTransport SRSharedAudioTransport;
typedef struct SRSharedAudioMapping SRSharedAudioMapping;
typedef struct SRSharedAudioBuffer SRSharedAudioBuffer;

typedef struct SRSharedAudioTransportConfiguration {
    uint32_t protocolVersion;
    uint32_t mappingSize;
    uint32_t outputLatencyFrames;
    char sharedMemoryName[SRSharedAudioTransportNameCapacity];
} SRSharedAudioTransportConfiguration;

typedef struct SRSharedAudioMetrics {
    uint64_t writtenFrames;
    uint64_t requestedRenderFrames;
} SRSharedAudioMetrics;

// App-side lifecycle. The transport creates a one-time named shared-memory object. After the
// driver maps it, unlink the name so no additional process can open the audio buffer.
SRSharedAudioTransport* _Nullable SRSharedAudioTransportCreate(
    uint32_t capacityFrames,
    uint32_t channelCount,
    uint32_t outputLatencyFrames
);
void SRSharedAudioTransportDestroy(SRSharedAudioTransport* _Nullable transport);
bool SRSharedAudioTransportCopyConfiguration(
    const SRSharedAudioTransport* _Nonnull transport,
    SRSharedAudioTransportConfiguration* _Nonnull configuration
);
const char* _Nullable SRSharedAudioTransportGetConfigurationToken(
    const SRSharedAudioTransport* _Nonnull transport
);
bool SRSharedAudioTransportUnlink(SRSharedAudioTransport* _Nonnull transport);
SRSharedAudioBuffer* _Nonnull SRSharedAudioTransportGetBuffer(
    SRSharedAudioTransport* _Nonnull transport
);

// Driver-side lifecycle. Opening validates both the configuration and the mapped header.
SRSharedAudioMapping* _Nullable SRSharedAudioMappingOpen(
    const SRSharedAudioTransportConfiguration* _Nonnull configuration
);
void SRSharedAudioMappingDestroy(SRSharedAudioMapping* _Nullable mapping);
SRSharedAudioBuffer* _Nonnull SRSharedAudioMappingGetBuffer(
    SRSharedAudioMapping* _Nonnull mapping
);

void SRSharedAudioTransportMakeDisconnectConfiguration(
    SRSharedAudioTransportConfiguration* _Nonnull configuration
);
bool SRSharedAudioTransportConfigurationIsDisconnect(
    const SRSharedAudioTransportConfiguration* _Nonnull configuration
);
bool SRSharedAudioTransportParseConfigurationToken(
    const char* _Nonnull token,
    SRSharedAudioTransportConfiguration* _Nonnull configuration
);

void SRSharedAudioBufferReset(SRSharedAudioBuffer* _Nonnull buffer);
uint32_t SRSharedAudioBufferWrite(
    SRSharedAudioBuffer* _Nonnull buffer,
    const float* _Nonnull interleavedSamples,
    uint32_t frameCount
);
uint32_t SRSharedAudioBufferRead(
    SRSharedAudioBuffer* _Nonnull buffer,
    float* _Nonnull interleavedSamples,
    uint32_t frameCount
);
uint32_t SRSharedAudioBufferReadWithDriftCompensation(
    SRSharedAudioBuffer* _Nonnull buffer,
    float* _Nonnull interleavedSamples,
    uint32_t frameCount
);
void SRSharedAudioBufferSetTargetGain(
    SRSharedAudioBuffer* _Nonnull buffer,
    float scalarGain
);
float SRSharedAudioBufferGetTargetGain(
    const SRSharedAudioBuffer* _Nonnull buffer
);
uint64_t SRSharedAudioBufferAvailableFrames(
    const SRSharedAudioBuffer* _Nonnull buffer
);
SRSharedAudioMetrics SRSharedAudioBufferGetMetrics(
    const SRSharedAudioBuffer* _Nonnull buffer
);

#ifdef __cplusplus
}
#endif

#endif
