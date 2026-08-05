# SpeakerRouterHAL

This target derives from Apple's “Creating an Audio Server Driver Plug-in”
sample, retained under the accompanying MIT-style `LICENSE.txt`.

Changes for SpeakerRouter:

- unique bundle, box, model, and device identifiers;
- SpeakerRouter product and localized device names;
- safe default output volume with a 0 dB maximum;
- the sample driver's established full-duplex object model, with an inert input
  stream retained for HAL compatibility;
- a declared `CFString` custom property and private shared-memory stereo ring
  that transfer the HAL output mix without the app opening an input device;
- physical-destination presentation latency supplied by the app and exposed
  through the virtual output for media synchronization.

Build from the repository root without installation:

```sh
./Scripts/build-driver.sh
```

The supported build path compiles both `NullAudio.c` and the shared-memory
transport into a universal ad-hoc-signed bundle. The app provides guarded
install, update, and uninstall actions; each action validates the expected
bundle identifier before modifying `/Library/Audio/Plug-Ins/HAL`.
