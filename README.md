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

## Local install

The HAL driver changes a system audio component and requires administrator
approval. Build it first, then run `Scripts/install-driver.sh` as root.
`Scripts/uninstall-driver.sh` only removes a bundle whose identifier is exactly
`com.liubaoyuan.SpeakerRouterHAL`.

Launch-at-login is registered only after `SpeakerRouter.app` has been copied
into `/Applications`; development builds under `DerivedData` deliberately do
not create a persistent login item.

The working product name is provisional.
