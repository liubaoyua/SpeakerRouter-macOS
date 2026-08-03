# SpeakerRouterHAL

This target derives from Apple's “Creating an Audio Server Driver Plug-in”
sample, retained under the accompanying MIT-style `LICENSE.txt`.

Changes for SpeakerRouter:

- unique bundle, box, model, and device identifiers;
- SpeakerRouter product and localized device names;
- safe default output volume with a 0 dB maximum;
- a preallocated lock-free stereo ring buffer that loops the HAL output mix into
  the input stream consumed by the relay app.

Build without installation:

```sh
xcodebuild -project NullAudio.xcodeproj -scheme NullAudio \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Do not install this driver while SpeakerAmp is the active system output. Driver
installation and end-to-end audio testing require an explicit migration step so
the current working audio route remains recoverable.
