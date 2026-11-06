#ifndef SRClientVolumes_h
#define SRClientVolumes_h

#include <CoreAudio/AudioServerPlugIn.h>

// Only Process is called from the real-time audio path.
void SRClientVolumesAdd(const AudioServerPlugInClientInfo* client);
void SRClientVolumesRemove(UInt32 clientID);
void SRClientVolumesStop(UInt32 clientID);
void SRClientVolumesProcess(UInt32 clientID, float* stereo, UInt32 frames);
CFArrayRef SRClientVolumesCopySnapshot(void);
OSStatus SRClientVolumesSetTargets(CFPropertyListRef value);

#endif
