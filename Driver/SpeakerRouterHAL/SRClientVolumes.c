#include "SRClientVolumes.h"

#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

enum { kMaxClients = 256 };

typedef struct {
    // key == 0 means free; all UInt32 client IDs are valid. Metadata is published
    // under the control lock. HAL drains a client's I/O before removing it.
    _Atomic uint64_t key;
    _Atomic uint64_t lastSignal;
    _Atomic float target;
    float current; // I/O thread only, except before publication or after removal.
    pid_t pid;
    int64_t registration;
    CFStringRef bundleID;
} Client;

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static Client gClients[kMaxClients];
static int64_t gLastRegistration;

static Client* findClient(UInt32 clientID) {
    uint64_t key = (uint64_t)clientID + 1;
    for (size_t i = 0; i < kMaxClients; i++) {
        if (atomic_load_explicit(&gClients[i].key, memory_order_acquire) == key) {
            return &gClients[i];
        }
    }
    return NULL;
}

void SRClientVolumesAdd(const AudioServerPlugInClientInfo* info) {
    pthread_mutex_lock(&gLock);
    if (!findClient(info->mClientID)) {
        for (size_t i = 0; i < kMaxClients; i++) {
            Client* client = &gClients[i];
            if (atomic_load_explicit(&client->key, memory_order_relaxed) != 0) {
                continue;
            }
            client->pid = info->mProcessID;
            int64_t now = (int64_t)mach_absolute_time();
            client->registration = gLastRegistration = now > gLastRegistration
                ? now : gLastRegistration + 1;
            client->bundleID = info->mBundleID ? CFRetain(info->mBundleID) : NULL;
            client->current = 1.0f;
            atomic_store_explicit(&client->target, 1.0f, memory_order_relaxed);
            atomic_store_explicit(&client->lastSignal, 0, memory_order_relaxed);
            atomic_store_explicit(&client->key, (uint64_t)info->mClientID + 1, memory_order_release);
            break;
        }
    }
    // If the table is full, audio from new clients still passes through at unity.
    pthread_mutex_unlock(&gLock);
}

void SRClientVolumesRemove(UInt32 clientID) {
    pthread_mutex_lock(&gLock);
    Client* client = findClient(clientID);
    if (client) {
        atomic_store_explicit(&client->key, 0, memory_order_release);
        if (client->bundleID) {
            CFRelease(client->bundleID);
            client->bundleID = NULL;
        }
    }
    pthread_mutex_unlock(&gLock);
}

void SRClientVolumesStop(UInt32 clientID) {
    pthread_mutex_lock(&gLock);
    Client* client = findClient(clientID);
    if (client) {
        atomic_store_explicit(&client->lastSignal, 0, memory_order_relaxed);
    }
    pthread_mutex_unlock(&gLock);
}

void SRClientVolumesProcess(UInt32 clientID, float* stereo, UInt32 frames) {
    Client* client = findClient(clientID);
    if (!client) {
        return;
    }
    // Measure before applying gain, so a muted but playing App remains in the menu.
    for (size_t i = 0; i < (size_t)frames * 2; i++) {
        if (fabsf(stereo[i]) > 0.000001f) {
            atomic_store_explicit(&client->lastSignal, mach_absolute_time(), memory_order_relaxed);
            break;
        }
    }
    float target = atomic_load_explicit(&client->target, memory_order_relaxed);
    float gain = client->current;
    if (gain == target && target == 1.0f) {
        return;
    }
    if (gain == target && target == 0.0f) {
        memset(stereo, 0, (size_t)frames * 2 * sizeof(float));
        return;
    }
    // Ramp in frame time, across callbacks. A full 0–200% sweep takes about 10 ms.
    const float step = 2.0f / 480.0f;
    for (size_t i = 0; i < (size_t)frames * 2; i += 2) {
        if (gain < target) {
            gain = fminf(gain + step, target);
        } else if (gain > target) {
            gain = fmaxf(gain - step, target);
        }
        stereo[i] *= gain;
        stereo[i + 1] *= gain;
    }
    client->current = gain;
}

CFArrayRef SRClientVolumesCopySnapshot(void) {
    CFMutableArrayRef rows = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    uint64_t activeTicks = UINT64_C(2000000000) * timebase.denom / timebase.numer;
    pthread_mutex_lock(&gLock);
    for (size_t i = 0; i < kMaxClients; i++) {
        Client* client = &gClients[i];
        if (atomic_load_explicit(&client->key, memory_order_relaxed) == 0 || client->pid <= 0) {
            continue;
        }
        uint64_t signal = atomic_load_explicit(&client->lastSignal, memory_order_relaxed);
        bool active = signal != 0 && mach_absolute_time() - signal <= activeTicks;
        float target = atomic_load_explicit(&client->target, memory_order_relaxed);
        CFNumberRef registration = CFNumberCreate(NULL, kCFNumberSInt64Type, &client->registration);
        CFNumberRef pid = CFNumberCreate(NULL, kCFNumberIntType, &client->pid);
        CFNumberRef gain = CFNumberCreate(NULL, kCFNumberFloatType, &target);
        const void* keys[] = { CFSTR("registration"), CFSTR("pid"), CFSTR("bundleID"), CFSTR("active"), CFSTR("gain") };
        const void* values[] = { registration, pid, client->bundleID ? client->bundleID : CFSTR(""),
            active ? kCFBooleanTrue : kCFBooleanFalse, gain };
        CFDictionaryRef row = CFDictionaryCreate(NULL, keys, values, 5,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(rows, row);
        CFRelease(row);
        CFRelease(gain);
        CFRelease(pid);
        CFRelease(registration);
    }
    pthread_mutex_unlock(&gLock);
    return rows;
}

OSStatus SRClientVolumesSetTargets(CFPropertyListRef value) {
    if (!value || CFGetTypeID(value) != CFArrayGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }
    CFArrayRef rows = (CFArrayRef)value;
    CFIndex count = CFArrayGetCount(rows);
    if (count > kMaxClients) {
        return kAudioHardwareIllegalOperationError;
    }
    int64_t registrations[kMaxClients];
    float gains[kMaxClients];
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef row = CFArrayGetValueAtIndex(rows, i);
        if (CFGetTypeID(row) != CFDictionaryGetTypeID()) {
            return kAudioHardwareIllegalOperationError;
        }
        CFNumberRef registration = CFDictionaryGetValue(row, CFSTR("registration"));
        CFNumberRef gain = CFDictionaryGetValue(row, CFSTR("gain"));
        if (!registration || CFGetTypeID(registration) != CFNumberGetTypeID() ||
            !CFNumberGetValue(registration, kCFNumberSInt64Type, &registrations[i]) ||
            !gain || CFGetTypeID(gain) != CFNumberGetTypeID() ||
            !CFNumberGetValue(gain, kCFNumberFloatType, &gains[i]) ||
            !isfinite(gains[i]) || gains[i] < 0.0f || gains[i] > 2.0f) {
            return kAudioHardwareIllegalOperationError;
        }
    }
    pthread_mutex_lock(&gLock);
    for (CFIndex i = 0; i < count; i++) {
        for (size_t j = 0; j < kMaxClients; j++) {
            Client* client = &gClients[j];
            if (client->registration == registrations[i] &&
                atomic_load_explicit(&client->key, memory_order_relaxed) != 0) {
                atomic_store_explicit(&client->target, gains[i], memory_order_relaxed);
                break;
            }
        }
    }
    pthread_mutex_unlock(&gLock);
    return noErr;
}
