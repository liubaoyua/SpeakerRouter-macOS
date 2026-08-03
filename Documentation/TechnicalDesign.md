# SpeakerRouter Technical Design

## Audio path

```text
macOS applications and system sounds
              |
              v
SpeakerRouter virtual output (system default + system sounds)
              |
              v
private shared memory -> gain/mute -> output AUHAL -> selected physical output
```

The virtual device exposes standard primary-volume and mute controls. This lets
macOS handle media keys and draw its native volume HUD. The app observes those
controls and maps them to a square-law software gain for useful low-volume
resolution; the physical device stays outside the system-default role. The app
never opens or changes an input device, so routing does not use the macOS
microphone-capture path.

## Components

### SpeakerRouterHAL.driver

A minimal C `AudioServerPlugIn` based on Apple's current virtual-device sample.
It keeps the sample driver's established full-duplex object model for HAL
compatibility, with two-channel 32-bit floating-point streams at 44.1 and 48 kHz
plus primary volume and mute controls. The input stream is inert and returns
silence; SpeakerRouterApp never opens it. The output callback writes the system
mix into a single-producer/single-consumer ring in a shared memory mapping
created by the app. A declared `CFString` custom device property carries a
one-time random mapping token to the remote driver service; the app unlinks the
name after the driver maps it.

The driver is installed under `/Library/Audio/Plug-Ins/HAL`. Local builds are
universal (`arm64` and `x86_64`) and ad-hoc signed. Public binary distribution
requires Developer ID signing and notarization.

### AudioRelayEngine

Creates the shared transport, attaches it to the virtual driver, and owns one
AUHAL audio unit for the physical-device output. The app has no input audio unit
or input device callback. Both the driver's writer and the app's physical-output
callback perform no allocation, file IO, logging, locks, or UI work. The app
requests 48 kHz from the virtual device; the relay format is interleaved stereo
32-bit float, and output AUHAL negotiates that client format with each selected
device. Explicit sample-rate conversion outside AUHAL is not yet implemented.

An output switch follows this sequence:

1. Ramp current software gain to silence.
2. Stop and destroy the physical-output AUHAL and disconnect the old mapping.
3. Create and attach a fresh shared mapping, then configure the new output AUHAL.
4. Start the selected physical output before making the virtual device default.
5. Ramp to the new device's remembered gain.

Underruns output silence. The shared header tracks only the physical render
callback frame count required by route-health recovery; it does not scan audio
samples or perform diagnostic work on either real-time thread.

### OutputDeviceRepository

Enumerates Core Audio output devices, identifies them by stable device UID, and
listens for device-list, liveness, name, transport, and sample-rate changes.
Virtual and aggregate devices are not eligible physical destinations to prevent
feedback loops.

Default classification:

- Bluetooth outputs and names containing AirPods, buds, headphone, headset, or
  their Chinese equivalents: headphones.
- HDMI and DisplayPort: display.
- Built-in output: built-in speaker unless its active source identifies a
  headphone port.
- USB: headphones only when the name or terminal source identifies a headset;
  otherwise other.

Classification only chooses the initial insertion point. The user's explicit
device order is authoritative afterward.

### RoutingController

The controller owns `RoutingState` and applies one deterministic policy:

```text
manual lock online -> locked device
manual lock offline -> clear lock, highest-priority online device
no manual lock      -> highest-priority online device
no physical output  -> stop relay and wait for a device-list change
```

The lock and all device preferences persist across app launches. Discovery uses
UID rather than display name so renaming and localization do not lose settings.
For switchable built-in hardware, the routing identity combines the hardware UID
and active output data-source ID. Wired headphones and the built-in speaker can
therefore keep separate priority and volume even when Core Audio exposes them as
the same hardware device.

### SpeakerRouterApp

A SwiftUI/AppKit `MenuBarExtra` window lists online and offline devices, permits
manual selection and reordering, shows the active output, and controls the
per-device volume. It starts at login and owns the relay lifecycle.

### SpeakerRouterGuard

A small child helper records the last known physical output and monitors an app
heartbeat. On clean termination the app restores that output itself. If the
parent exits or the heartbeat expires, the guard sets the last known physical
device as default output and system-sound output so a crashed relay cannot leave
the Mac silent.

## Persistence

The initial implementation stores a versioned JSON-compatible configuration:

- ordered device preferences keyed by UID;
- last known name, kind, and transport;
- per-device scalar volume;
- optional manual-lock UID;
- last known usable physical output UID.

Writes are atomic and occur only outside audio callbacks.

## Verification strategy

Pure Swift tests cover priority insertion, custom ordering, manual-lock
retention, lock removal on disconnect, volume clamping, and persistence. Core
Audio integration tests use a fake device repository first. Manual acceptance
on the Mac covers HDMI/DP, wired, Bluetooth, USB, media keys, sleep/wake,
hot-plugging, app quit, and forced termination.
