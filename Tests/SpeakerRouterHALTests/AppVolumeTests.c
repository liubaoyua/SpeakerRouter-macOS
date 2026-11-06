#include <CoreAudio/AudioServerPlugIn.h>
#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>

#include "SRAppVolume.h"
#include "SRSharedAudioTransport.h"

enum { kDevice = 3, kOutputStream = 8, kFrames = 8192 };
static AudioServerPlugInDriverRef driver;
static const AudioServerPlugInIOCycleInfo cycle;
static const AudioObjectPropertyAddress volumeAddress = {
    SRAppVolumePropertySelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};

static CFDictionaryRef copyClient(pid_t pid) {
    CFArrayRef snapshot = NULL;
    UInt32 size = 0;
    assert((*driver)->GetPropertyData(driver, kDevice, 0, &volumeAddress, 0, NULL,
        sizeof(snapshot), &size, &snapshot) == noErr);
    CFDictionaryRef found = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(snapshot); i++) {
        CFDictionaryRef row = CFArrayGetValueAtIndex(snapshot, i);
        CFNumberRef number = CFDictionaryGetValue(row, CFSTR("pid"));
        pid_t candidate = 0;
        assert(CFNumberGetValue(number, kCFNumberIntType, &candidate));
        if (candidate == pid) {
            found = CFRetain(row);
            break;
        }
    }
    CFRelease(snapshot);
    assert(found);
    return found;
}

static OSStatus setGain(CFDictionaryRef client, float gain) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloatType, &gain);
    const void* keys[] = { CFSTR("registration"), CFSTR("gain") };
    const void* values[] = { CFDictionaryGetValue(client, CFSTR("registration")), number };
    CFDictionaryRef entry = CFDictionaryCreate(NULL, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef command = CFArrayCreate(NULL, (const void**)&entry, 1, &kCFTypeArrayCallBacks);
    OSStatus status = (*driver)->SetPropertyData(
        driver, kDevice, 0, &volumeAddress, 0, NULL, sizeof(command), &command
    );
    CFRelease(command);
    CFRelease(entry);
    CFRelease(number);
    return status;
}

static void process(UInt32 client, float* samples, UInt32 frames, float sample) {
    for (size_t i = 0; i < frames * 2; i++) {
        samples[i] = sample;
    }
    assert((*driver)->DoIOOperation(driver, kDevice, kOutputStream, client,
        kAudioServerPlugInIOOperationProcessOutput, frames, &cycle, samples, NULL) == noErr);
}

static void connectTransport(CFStringRef token) {
    const AudioObjectPropertyAddress address = {
        SRSharedAudioTransportPropertySelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    assert((*driver)->SetPropertyData(driver, kDevice, 0, &address, 0, NULL,
        sizeof(token), &token) == noErr);
}

int main(int argc, char** argv) {
    assert(argc == 2);
    void* bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(bundle);
    void* (*create)(CFAllocatorRef, CFUUIDRef) = dlsym(bundle, "NullAudio_Create");
    assert(create);
    driver = create(NULL, kAudioServerPlugInTypeUUID);
    assert(driver);

    // Mimic two WKWebViews. They share a helper bundle ID but must never share gain.
    AudioServerPlugInClientInfo first = { 1, 101, true, CFSTR("com.apple.WebKit.WebContent") };
    AudioServerPlugInClientInfo second = { 2, 102, true, CFSTR("com.apple.WebKit.WebContent") };
    assert((*driver)->AddDeviceClient(driver, kDevice, &first) == noErr);
    assert((*driver)->AddDeviceClient(driver, kDevice, &second) == noErr);
    Boolean supported = false, inPlace = false;
    assert((*driver)->WillDoIOOperation(driver, kDevice, first.mClientID,
        kAudioServerPlugInIOOperationProcessOutput, &supported, &inPlace) == noErr);
    assert(supported && inPlace);
    assert((*driver)->StartIO(driver, kDevice, first.mClientID) == noErr);
    assert((*driver)->StartIO(driver, kDevice, second.mClientID) == noErr);

    CFDictionaryRef firstClient = copyClient(first.mProcessID);
    CFDictionaryRef secondClient = copyClient(second.mProcessID);
    assert(CFDictionaryGetValue(firstClient, CFSTR("active")) == kCFBooleanFalse);
    assert(setGain(firstClient, 1.5f) == noErr);
    assert(setGain(firstClient, NAN) != noErr);
    assert(setGain(firstClient, 2.1f) != noErr);
    float a[kFrames * 2], b[kFrames * 2];
    process(first.mClientID, a, 64, 0.2f);
    assert(a[0] > 0.2f && a[126] < 0.3f); // Must ramp across callbacks.
    process(first.mClientID, a, kFrames, 0.2f);
    process(second.mClientID, b, kFrames, -0.1f);
    for (size_t i = 512; i < kFrames * 2; i++) {
        assert(fabsf(a[i] - 0.3f) < 0.00001f && b[i] == -0.1f);
    }

    // The existing ring receives the full large batch after the HAL mixes these buffers.
    SRSharedAudioTransport* transport = SRSharedAudioTransportCreate(kFrames * 2, 2, 0);
    assert(transport);
    CFStringRef token = CFStringCreateWithCString(NULL,
        SRSharedAudioTransportGetConfigurationToken(transport), kCFStringEncodingUTF8);
    connectTransport(token);
    CFRelease(token);
    assert(SRSharedAudioTransportUnlink(transport));
    for (size_t i = 0; i < kFrames * 2; i++) {
        a[i] += b[i];
    }
    assert((*driver)->DoIOOperation(driver, kDevice, kOutputStream, 0,
        kAudioServerPlugInIOOperationWriteMix, kFrames, &cycle, a, NULL) == noErr);
    assert(SRSharedAudioBufferRead(SRSharedAudioTransportGetBuffer(transport), b, kFrames) == kFrames);
    assert(fabsf(b[kFrames * 2 - 1] - 0.2f) < 0.00001f);

    assert(setGain(firstClient, 0.0f) == noErr);
    process(first.mClientID, a, kFrames, 0.2f);
    assert(a[kFrames * 2 - 1] == 0.0f);
    CFDictionaryRef muted = copyClient(first.mProcessID);
    assert(CFDictionaryGetValue(muted, CFSTR("active")) == kCFBooleanTrue);
    CFRelease(muted);

    assert(setGain(firstClient, 1.0f) == noErr);
    process(first.mClientID, a, kFrames, 0.2f);
    assert(a[kFrames * 2 - 1] == 0.2f);

    assert(setGain(firstClient, 2.0f) == noErr);
    assert(setGain(secondClient, 2.0f) == noErr);
    process(first.mClientID, a, kFrames, 0.8f);
    process(second.mClientID, b, kFrames, 0.8f);
    float peaks[] = {0.4f, -0.2f, a[kFrames * 2 - 1] + b[kFrames * 2 - 1], -1.6f, 0.4f, -0.2f};
    SRPeakLimiter limiter;
    SRPeakLimiterReset(&limiter, 48000);
    SRPeakLimiterProcessStereo(&limiter, peaks, 3);
    assert(peaks[0] == 0.4f && peaks[1] == -0.2f); // Linear within headroom.
    assert(fabsf(peaks[2] - 1.0f) < 0.00001f && fabsf(peaks[3] + 0.5f) < 0.00001f);
    assert(fabsf(peaks[4] - 0.125f) < 0.00001f); // Briefly hold through low-frequency peaks.
    process(first.mClientID, a, kFrames, 0.2f);
    SRPeakLimiterProcessStereo(&limiter, a, kFrames);
    assert(a[1600] > 0.125f && a[1600] < 0.4f); // Releases gradually.
    assert(a[kFrames * 2 - 1] == 0.4f);

    // Reusing a HAL client ID must not let a stale UI write affect the replacement.
    assert((*driver)->StopIO(driver, kDevice, first.mClientID) == noErr);
    CFDictionaryRef stopped = copyClient(first.mProcessID);
    assert(CFDictionaryGetValue(stopped, CFSTR("active")) == kCFBooleanFalse);
    CFRelease(stopped);
    assert((*driver)->RemoveDeviceClient(driver, kDevice, &first) == noErr);
    first.mProcessID = 103;
    assert((*driver)->AddDeviceClient(driver, kDevice, &first) == noErr);
    assert((*driver)->StartIO(driver, kDevice, first.mClientID) == noErr);
    assert(setGain(firstClient, 0.0f) == noErr);
    process(first.mClientID, a, kFrames, 0.2f);
    assert(a[0] == 0.2f && a[kFrames * 2 - 1] == 0.2f);

    connectTransport(CFSTR(""));
    assert((*driver)->StopIO(driver, kDevice, first.mClientID) == noErr);
    assert((*driver)->StopIO(driver, kDevice, second.mClientID) == noErr);
    assert((*driver)->RemoveDeviceClient(driver, kDevice, &first) == noErr);
    assert((*driver)->RemoveDeviceClient(driver, kDevice, &second) == noErr);
    SRSharedAudioTransportDestroy(transport);
    CFRelease(firstClient);
    CFRelease(secondClient);
    puts("PASS: two-client gain isolation, mute/reset, 8192-frame relay, peak protection, and client reuse");
    return 0;
}
