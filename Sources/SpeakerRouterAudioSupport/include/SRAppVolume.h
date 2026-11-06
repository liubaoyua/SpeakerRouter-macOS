#ifndef SRAppVolume_h
#define SRAppVolume_h

#define SRAppVolumePropertySelector 0x53526176u /* 'SRav' */

typedef struct SRPeakLimiter {
    float gain;
    float releaseStep;
    unsigned int holdFrames;
    unsigned int holdRemaining;
} SRPeakLimiter;

void SRPeakLimiterReset(SRPeakLimiter* _Nonnull limiter, double sampleRate);
void SRPeakLimiterProcessStereo(
    SRPeakLimiter* _Nonnull limiter, float* _Nonnull samples, unsigned int frameCount
);

#endif
