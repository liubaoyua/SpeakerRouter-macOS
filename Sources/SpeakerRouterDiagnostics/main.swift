import Foundation
import SpeakerRouterCore

do {
  let repository = CoreAudioDeviceRepository()
  let systemController = CoreAudioSystemController()
  let devices = try repository.outputDevices()
  let defaultOutputID = try systemController.defaultOutputDeviceID()
  let defaultOutputUID = systemController.deviceUID(for: defaultOutputID) ?? "unknown"
  let virtualDeviceID = try systemController.deviceID(
    forUID: CoreAudioSystemController.speakerRouterDeviceUID
  )

  if CommandLine.arguments.count == 3,
    CommandLine.arguments[1] == "--set-virtual-volume",
    let requestedVolume = Float(CommandLine.arguments[2]),
    let virtualDeviceID
  {
    try systemController.setOutputVolume(requestedVolume, of: virtualDeviceID)
  }

  print("Default output UID: \(defaultOutputUID)")
  print("SpeakerRouterHAL installed: \(virtualDeviceID != nil ? "yes" : "no")")
  if let virtualDeviceID,
    let volume = systemController.outputVolume(of: virtualDeviceID)
  {
    print("SpeakerRouterHAL volume: \(volume)")
    print("SpeakerRouterHAL muted: \(systemController.outputMute(of: virtualDeviceID))")
  }
  print("Eligible physical output devices: \(devices.count)")
  for device in devices {
    print(
      [
        device.kind.rawValue,
        device.transport.rawValue,
        device.name,
        device.manufacturer,
        device.uid,
        device.hardwareUID,
        device.dataSourceName ?? "-",
      ].joined(separator: "\t")
    )
  }
} catch {
  fputs("Core Audio enumeration failed: \(error)\n", stderr)
  exit(EXIT_FAILURE)
}
