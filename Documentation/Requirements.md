# SpeakerRouter Requirements

## Goal

Provide reliable software volume control and deterministic output-device
selection on macOS, including outputs whose hardware volume cannot be adjusted
by the system.

## Required behavior

1. Support wired headphones, Bluetooth headphones, USB audio, HDMI/DisplayPort,
   AirPlay, and the built-in speaker.
2. Show previously discovered outputs, including devices that are offline.
3. Let the user reorder individual devices. Newly discovered devices default to
   headphones, displays, built-in speakers, then other outputs.
4. In automatic mode, select the highest-priority online device.
5. A manual selection remains authoritative until that device disconnects.
6. Disconnecting the manually selected device clears the lock and selects the
   highest-priority remaining output.
7. Remember volume per physical output. New devices start at 30 percent; gain
   stays between 0 and 100 percent with no boost.
8. Switch outputs with a short gain ramp and no notification sound.
9. Support standard volume and mute keys plus the native volume HUD.
10. Run as a menu bar app and optionally launch at login.
11. Never open, select, or modify an input device for normal routing.
12. Restore a physical output on clean exit. A lightweight guard must also
    recover it if the app crashes or stops sending a heartbeat.
13. A route-start failure must not trigger an unbounded or high-frequency retry
    loop. Retry only after a device change or explicit user action.
14. Driver installation and removal must validate the expected bundle identifier
    before modifying `/Library/Audio/Plug-Ins/HAL`.
15. Independent virtual and physical clocks must not accumulate unbounded queued
    audio. The virtual device must expose downstream presentation latency.
16. Disconnecting the active headphone output pauses system media before routing
    falls back to another device.
17. Removing the active AirPods pauses media only when it was playing. Reinserting
    them resumes only when SpeakerRouter confirmed that removal caused the pause.

## Acceptance scenarios

- With only the built-in speaker online, automatic mode selects it.
- Connecting a higher-priority display or headphone changes the route only when
  no manual lock exists.
- Manually selecting a display keeps it selected when headphones connect.
- Disconnecting that display clears the lock and chooses the next online device.
- Returning to a device restores its saved volume.
- Volume and mute keys change the virtual-device controls and relay gain.
- Sleeping, waking, and Core Audio service restarts recover without rapid route
  reconstruction or a loud transient.
- Quitting or crashing the app leaves macOS with a usable physical output.
- Normal operation does not request microphone permission or show the recording
  indicator.
- Long playback through a wireless output remains bounded in latency; pausing
  does not drain seconds of stale buffered audio.
- Disconnecting active headphones pauses current media without toggling already
  paused media back into playback.
- Removing active AirPods pauses playing media. Reinserting them resumes that
  playback, but does not resume media that was already paused before removal.

## Out of scope for the current release

- App Store distribution and automatic updates.
- Equalization, effects, visualization, or gain above 100 percent.
- Network control, telemetry, or cloud synchronization.
