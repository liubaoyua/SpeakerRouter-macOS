# Changelog

All notable changes are documented in this file.

## 0.6.0 - 2026-08-04

- Added bounded-latency clock-drift compensation for independent virtual and
  physical output clocks.
- Discard stale multi-second audio backlog and smoothly interpolate the
  occasional extra or repeated source frame.
- Report the physical destination and relay presentation latency through the
  virtual output so media clients can maintain audio/video synchronization.
- Forward an idempotent media Pause when the active headphone output disconnects.
- Pause media when the active AirPods are removed and resume only when the App
  previously paused that playback, using local Bluetooth proximity broadcasts.
- Avoid the entitlement-gated MediaRemote playback-state query and infer recent
  playback from virtual-audio producer progress, preventing an AirPods-removal crash.
- Reassert Pause once after 750 ms while an AirPod remains removed, covering media
  clients such as Chrome that briefly acknowledge Pause and immediately resume.
- Resume playback immediately after AirPods report a worn-again transition,
  while still requiring SpeakerRouter to have paused it after removal.
- Read real-time playback state through the BSD-licensed MediaRemote Adapter
  helper, re-pause clients that resume after removal, and retain audio-frame
  activity as a fallback when the private framework workaround is unavailable.
- Observe connected-AirPods AACP placement events through a narrowly filtered
  system log stream, retaining proximity advertisements as a fallback when
  connected-device placement is not rebroadcast over BLE.

## 0.5.1 - 2026-08-03

- Blocked routing when the installed HAL driver does not match the bundled
  version, replacing a low-level shared-transport error with an update prompt.
- Wait for `coreaudiod` to load the replacement driver before reconnecting the
  shared-memory transport.

## 0.5.0 - 2026-08-03

- Replaced virtual-input capture with a private shared-memory audio transport.
- Removed microphone access from the App and eliminated the recording indicator.
- Added guarded in-app driver installation, update, reinstall, and removal.
- Added callback-liveness recovery and same-route failure circuit breaking.
- Moved Core Audio enumeration off the main thread to prevent UI hangs.
- Added macOS App and resolution-independent menu bar icons.
- Removed temporary live diagnostics, debug-window hooks, the diagnostics CLI,
  obsolete ring-buffer code, and stale sample-project files.
- Added public build, contribution, security, troubleshooting, and licensing
  documentation.
