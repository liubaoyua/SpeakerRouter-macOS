#include "SRAppVolume.h"

#include <math.h>
#include <stddef.h>

void SRPeakLimiterReset(SRPeakLimiter* limiter, double sampleRate) {
    limiter->gain = 1.0f;
    limiter->releaseStep = (float)(1.0 / (sampleRate * 0.10));
    limiter->holdFrames = (unsigned int)(sampleRate * 0.012);
    limiter->holdRemaining = 0;
}

void SRPeakLimiterProcessStereo(SRPeakLimiter* limiter, float* samples, unsigned int frameCount) {
    float gain = limiter->gain;
    unsigned int hold = limiter->holdRemaining;
    for (size_t i = 0; i < (size_t)frameCount * 2; i += 2) {
        float left = isfinite(samples[i]) ? samples[i] : 0.0f;
        float right = isfinite(samples[i + 1]) ? samples[i + 1] : 0.0f;
        float peak = fmaxf(fabsf(left), fabsf(right));
        // Instant attack, linked stereo and a short hold to avoid restoring gain
        // between bass peaks. No lookahead or added buffering.
        float ceiling = peak > 1.0f ? 1.0f / peak : 1.0f;
        if (ceiling <= gain && ceiling < 1.0f) {
            gain = ceiling;
            hold = limiter->holdFrames;
        } else if (hold > 0) {
            hold--;
        } else if (gain < 1.0f) {
            gain = fminf(ceiling, gain + limiter->releaseStep);
        }
        samples[i] = left * gain;
        samples[i + 1] = right * gain;
    }
    limiter->gain = gain;
    limiter->holdRemaining = hold;
}
