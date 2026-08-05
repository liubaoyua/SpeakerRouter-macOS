# Development Status

## Implemented

- Menu bar UI with online/offline devices, automatic and manual routing,
  priority ordering, per-device volume, and launch-at-login control.
- Core Audio discovery and hot-plug listeners for built-in, wired, Bluetooth,
  USB, HDMI, DisplayPort, AirPlay, and other output transports.
- Stable identities for switchable built-in data sources such as internal
  speakers and wired headphones.
- Universal `arm64`/`x86_64` AudioServerPlugIn with standard volume and mute
  controls.
- Shared-memory transfer from the virtual output callback to a physical-output
  AUHAL callback without opening an input device.
- Bounded-latency drift compensation and downstream presentation-latency
  reporting for devices with independent clocks.
- Active-AirPods removal pause and guarded reinsertion resume from local
  Bluetooth proximity advertisements.
- Address-filtered connected-AirPods AACP placement monitoring, with BLE
  proximity advertisements retained as a fallback.
- Real-time now-playing state and commands through a bundled BSD MediaRemote
  Adapter helper, with producer-frame fallback and resume re-pause handling.
- Failed-route circuit breaker and callback-liveness recovery.
- Guard helper that restores the last physical output after app failure.
- Guarded in-app driver installation, update, reinstall, and removal.
- Reproducible command-line builds with ad-hoc signing.
- Pinned third-party source and in-bundle BSD license notice.

## Automated verification

- Routing priority, manual lock, disconnect fallback, volume, persistence, and
  heartbeat unit tests, plus AirPods placement and playback-transition tests.
- Shared-memory token parsing, independent mappings, gain ramp, underflow
  silence, overrun behavior, sustained clock drift, stale-backlog recovery,
  latency conversion, and callback-liveness tests.
- Strict C warnings during driver build.
- Universal driver architecture and deep App bundle signature checks in the
  documented release workflow.

## Manual verification still required

- Representative HDMI/DisplayPort, wired, Bluetooth, USB, and AirPlay devices.
- AirPods placement behavior across models, firmware versions, and one-ear use.
- MediaRemote Adapter behavior after macOS updates and with different browser
  media-session implementations.
- Stability of the internal `bluetoothd` AACP log format across macOS releases.
- Sleep/wake, login, Core Audio restart, and driver update boundaries.
- Long-running latency, buffer pressure, and clock-drift behavior.
- Gatekeeper behavior after Developer ID signing and notarization.

The repository does not claim universal hardware compatibility until these
scenarios have been exercised on multiple Macs and third-party audio drivers.
