# SpeakerRouter

SpeakerRouter is a self-use macOS menu bar app that routes system audio to the
best available physical output while keeping software volume control available
for HDMI and DisplayPort displays.

The project is intentionally split into two layers:

- `SpeakerRouterCore`: device models, routing policy, manual lock behavior, and
  per-device volume persistence.
- `SpeakerRouterApp`: the macOS menu bar UI and Core Audio device discovery.

The virtual Audio Server plug-in and real-time relay engine are described in
[`Documentation/TechnicalDesign.md`](Documentation/TechnicalDesign.md).

## Build and test

```sh
swift test
swift build
./Scripts/build-driver.sh
./Scripts/build-app.sh
```

Build products are written below `DerivedData/`. On the current development Mac,
the app is installed at `/Applications/SpeakerRouter.app` and the driver at
`/Library/Audio/Plug-Ins/HAL/SpeakerRouterHAL.driver`. SpeakerAmp remains
installed as a known fallback.

For local UI verification, the app can expose the same menu content in a normal
window:

```sh
./DerivedData/Products/SpeakerRouter.app/Contents/MacOS/SpeakerRouterApp --show-window
```

The `--show-window` option is only a test hook. A normal launch remains a
menu-bar-only app.

## Driver management

The packaged app includes its matching HAL driver. The menu bar UI shows whether
the driver is missing, current, or needs an update, and provides install/update,
reinstall, and uninstall actions. macOS requests administrator approval before
any of these actions modify `/Library/Audio/Plug-Ins/HAL`.

For command-line development, build the driver first and run
`Scripts/install-driver.sh` as root. Both the UI and command-line scripts share
the same guarded helper, which only replaces or removes a bundle whose identifier
is exactly `com.liubaoyuan.SpeakerRouterHAL`.

SpeakerRouter is one full-duplex Core Audio device: it appears once under Output
and once under Input. The input stream is how the relay receives the system mix;
it is not an additional installed driver. Unused data-source selectors from the
upstream sample driver are intentionally not exposed.

The app verifies routing health from live capture and render frame counters. If
both callbacks stop advancing after an audio-service restart, SpeakerRouter
automatically tears down the stale Core Audio objects and rebuilds the route.
It also keeps a silent output client attached to the virtual device so existing
players cannot leave the system-mix writer dormant after the default device
changes.

Launch-at-login is registered only after `SpeakerRouter.app` has been copied
into `/Applications`; development builds under `DerivedData` deliberately do
not create a persistent login item.

The working product name is provisional.
