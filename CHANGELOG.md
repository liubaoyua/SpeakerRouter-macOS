# Changelog

All notable changes are documented in this file.

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
