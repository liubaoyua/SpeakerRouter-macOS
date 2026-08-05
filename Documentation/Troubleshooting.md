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

## AirPods audio is delayed or continues after pause

Version 0.6.0 and driver 0.5.0 add clock-drift compensation and downstream
latency reporting. Update both components; an older installed driver cannot
publish the physical destination latency. Reconnect the AirPods after updating
if macOS still has the previous Bluetooth route cached.

## AirPods removal does not pause or reinsertion does not resume

1. In System Settings > Privacy & Security > Bluetooth, allow SpeakerRouter.
2. Confirm the selected physical output is an AirPods device; monitoring stops
   for every other output.
3. SpeakerRouter resumes only playback that it confirmed was playing and then
   paused on removal. Media that was already paused stays paused.
4. The placement advertisement is not a public Apple API. An unsupported model
   safely continues routing audio without automatic media control; include the
   AirPods model and firmware version in a bug report.
5. Build 24 and later determine recent playback from the virtual audio producer.
   Build 23 can crash on removal because its private playback-state query is
   rejected by current macOS releases. Build 25 also retries Pause once for
   clients that briefly acknowledge the first command and immediately resume.

## Safe diagnostic information for bug reports

Include:

- macOS version and Mac model;
- App and bundled driver versions shown in the menu;
- physical device name and connection type;
- whether the problem started after install, wake, hot-plug, or route switching;
- whether the system default output is SpeakerRouter or a physical device.

Do not include passwords, authorization dialogs, or unrelated system logs.
