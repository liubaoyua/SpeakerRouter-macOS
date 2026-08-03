# SpeakerRouter v0.1 Requirements

## Goal

Provide reliable software volume control and deterministic output-device
selection on the user's Mac mini, including outputs whose hardware volume is
not adjustable by macOS.

## Required behavior

1. Support wired headphones, AirPods and other Bluetooth headphones, USB audio
   outputs, HDMI/DisplayPort displays, and the Mac mini built-in speaker.
2. Show every previously discovered output, including devices that are offline.
3. Let the user manually reorder individual devices. For newly discovered
   devices, the default category order is headphones, displays, built-in
   speaker, then other outputs.
4. In automatic mode, select the highest-priority online device.
5. A manual selection locks routing to that device even if a higher-priority
   device later appears. The lock survives sleep and app relaunch while the
   selected device remains online.
6. When the manually selected device disconnects, clear the lock and fall back
   to the highest-priority online device.
7. Remember volume separately for each physical output. New devices start at
   30 percent. The supported range is 0 through 100 percent with no boost.
8. Switch outputs with a short gain ramp and no notification sound.
9. Support the standard macOS volume keys, mute key, and native volume HUD.
10. Run as a menu bar app and launch at login.
11. Never change the default input device or microphone configuration.
12. Restore a usable physical system output on clean exit. A lightweight guard
    process must recover the physical output if the relay app crashes or stops
    sending a heartbeat.
13. The first release is for personal use. App Store packaging, auto-update,
    equalization, effects, spectrum display, and gain above 100 percent are out
    of scope.

## Acceptance scenarios

- With only the Mac mini speaker online, it is selected automatically.
- Connecting a display selects it when no manual lock exists and it outranks the
  built-in speaker.
- Connecting any configured headphone selects it when no manual lock exists and
  it outranks the current output.
- Manually selecting a display keeps it selected when headphones connect.
- Disconnecting that manually selected display clears the lock and selects the
  highest-priority remaining device.
- Returning to a device restores its previous volume.
- Volume and mute keys update the virtual device and therefore the relay gain.
- Sleeping and waking preserves a valid route without a loud transient.
- Quitting or crashing the relay leaves the Mac with a usable physical output.
