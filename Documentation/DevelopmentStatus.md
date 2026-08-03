# Development status

## Implemented

- macOS menu bar UI with online/offline device rows, manual selection, priority
  movement, per-device volume, automatic-mode reset, and launch-at-login control.
- Physical device discovery for DisplayPort, HDMI, built-in, Bluetooth, USB,
  AirPlay, and other Core Audio transports.
- Separate routing identities for the built-in speaker and wired headphones when
  macOS represents both as data sources of one hardware device.
- Device-list and per-device listeners for hot-plug, active data source, name,
  liveness, and nominal sample-rate changes.
- Deterministic automatic priority, persistent manual lock, lock removal on
  disconnect, offline history, and per-route volume persistence.
- Square-law 0 to 100 percent software gain, mute, and short gain ramps.
- A C11 SPSC float ring buffer used by the real-time relay path.
- Direct virtual-device IO procedure plus AUHAL physical output relay.
- Core Audio default-output/system-output control with rollback on partial error.
- Native virtual-device volume and mute monitoring for media keys and HUD.
- A crash/hang guard helper that restores the last physical output after a stale
  heartbeat.
- A universal arm64/x86_64 HAL driver derived from Apple's licensed NullAudio
  sample, with an output-to-input loopback buffer.
- Reproducible self-use `.driver` and `.app` build scripts with ad-hoc signing.

## Verified on the current Mac (macOS 26.3)

- Swift package debug and release builds.
- 12 deterministic unit tests for routing, persistence, volume, heartbeat, and
  ring-buffer behavior.
- Strict C11 syntax/warning checks and Clang static analysis.
- Driver universal architectures, exported factory, property list, and signature.
- App bundle, embedded guard executable, property list, and deep signature.
- Live read-only discovery of P275MV (DisplayPort), VX2780 Series (HDMI), and the
  Mac mini built-in speaker.
- The built-in speaker is currently identified as data source `1769173099`,
  proving the source-aware route identity is active.
- Menu-window interaction for ordering, automatic selection, manual lock,
  per-device volume, and the visible route status.
- The HAL bundle loads in the separate Core Audio driver process and publishes
  `SpeakerRouterHAL_Device_UID` with working volume and mute controls.
- SpeakerRouter is the default output and system-sound output while the app is
  running; the current route is SpeakerRouter -> P275MV at 30 percent.
- A system media-volume key changes the virtual device and is reflected back in
  the app's per-device volume state.
- Runtime relay counters prove that non-silent PCM is captured and rendered,
  with zero underflow during the current checks. The first AUHAL-input approach
  exposed zero captured frames and was replaced with a direct device IO
  procedure before the installed build was finalized.
- P275MV, VX2780 Series, and the Mac mini speaker each started as physical
  destinations with live captured/rendered PCM; the user also confirmed normal
  device switching.
- Clean exit restores P275MV and stops the guard. A forced `SIGKILL` also caused
  the guard to restore P275MV in under one second.
- `/Applications/SpeakerRouter.app` is installed, runs as a menu-bar-only app,
  and has an enabled launch-at-login registration pointing at that stable path.
- Existing SpeakerAmp remains installed and was not modified.

## Remaining hardware and endurance verification

- Test wired headphones, AirPods/Bluetooth, and a USB audio output as those
  devices become available.
- Test disconnect/reconnect boundaries for manual lock on real hardware.
- Test sleep/wake and login-after-reboot behavior.
- Tune buffer size/clock-drift handling from real underrun and latency evidence.
- Add Developer ID signing and notarization before sharing the build with other
  Macs; the current app and driver are deliberately ad-hoc signed for self-use.

The current DisplayPort route is verified at the Core Audio process level. The
unavailable device classes above are implemented but not yet hardware-verified.
