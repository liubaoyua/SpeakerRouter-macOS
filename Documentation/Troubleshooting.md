# Troubleshooting

## The menu bar icon does not appear

1. Confirm SpeakerRouter is running in Activity Monitor.
2. Quit the existing process before replacing the App bundle; copying a new
   bundle does not update an already-running process.
3. Open the copy under `/Applications`, not a stale build elsewhere.

## The driver status is unknown or out of date

Use the App's reinstall/update action. The bundled and installed driver versions
must match. Do not copy an individual driver binary into an existing bundle.

The installed bundle should be located at:

```text
/Library/Audio/Plug-Ins/HAL/SpeakerRouterHAL.driver
```

## The route has no sound

1. Return the default output to a known physical speaker if possible.
2. Quit SpeakerRouter completely.
3. Reopen it and select the physical destination again.
4. If the App reports a route-start failure, do not repeatedly click install or
   update. Capture the displayed error and the macOS version first.
5. If Core Audio remains unresponsive after the driver has been removed, reboot
   before reinstalling. Other third-party HAL drivers may also need isolation.

The App deliberately blocks repeated attempts for the same failed route until a
device changes or the user explicitly retries, preventing a Core Audio property
reconciliation loop.

## Safe diagnostic information for bug reports

Include:

- macOS version and Mac model;
- App and bundled driver versions shown in the menu;
- physical device name and connection type;
- whether the problem started after install, wake, hot-plug, or route switching;
- whether the system default output is SpeakerRouter or a physical device.

Do not include passwords, authorization dialogs, or unrelated system logs.
