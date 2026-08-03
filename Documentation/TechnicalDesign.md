# SpeakerRouter Technical Design

## Audio path

```text
macOS applications and system sounds
              |
              v
SpeakerRouter virtual output (system default output + system-sound output)
              |
              v
lock-free ring buffer -> gain/mute -> format conversion -> selected physical output
```

The virtual device exposes standard primary-volume and mute controls. This lets
macOS handle media keys and draw its native volume HUD. The app observes those
controls and maps them to a square-law software gain for useful low-volume
resolution; the physical device stays outside the
system-default role. The app never changes the default input device.

## Components

### SpeakerRouterHAL.driver

A minimal C `AudioServerPlugIn` based on Apple's current virtual-device sample.
It publishes one two-channel, 32-bit floating-point device with 44.1 and 48 kHz
formats, primary volume, and mute controls. Its output stream is looped back to
an input stream consumed only by the relay app.

The first implementation is installed under `/Library/Audio/Plug-Ins/HAL` for
personal use. It must be universal (`arm64` and `x86_64`) and signed before it
is treated as distributable; ad-hoc local development is acceptable initially.

### AudioRelayEngine

Uses `AudioDeviceCreateIOProcID` to consume the virtual-device input and one
AUHAL audio unit for the physical-device output. The direct device callback is
required because an input-only AUHAL client did not start virtual-driver input
delivery on the current macOS 26.3 system.
The real-time callbacks perform no allocation, file IO, logging, locks, or UI
work. A preallocated single-producer/single-consumer ring buffer crosses the two
device clock domains. The app requests 48 kHz from the virtual device; the
current relay format is interleaved stereo 32-bit float, and output AUHAL
negotiates that client format with each selected device. Explicit sample-rate
conversion outside AUHAL is not yet implemented.

An output switch follows this sequence:

1. Ramp current software gain to silence.
2. Stop and destroy the virtual-device IO procedure and physical-output AUHAL.
3. Reset the ring buffer and bind a new input IO procedure and output AUHAL.
4. Start the virtual input IO procedure and selected physical output.
5. Ramp to the new device's remembered gain.

Underruns output silence and increment a non-real-time diagnostic counter.

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
