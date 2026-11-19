import Darwin
import Foundation
import IOBluetooth
import SpeakerRouterCore

// This helper isolates potentially blocking Bluetooth calls from the App's UI
// and audio threads. The parent also enforces a 12-second process deadline.
guard CommandLine.arguments.count == 2,
  let address = BluetoothDeviceAddress.from(hardwareUID: CommandLine.arguments[1]),
  let device = IOBluetoothDevice(addressString: address),
  device.isPaired(), device.isConnected(),
  device.name?.localizedCaseInsensitiveContains("airpods") == true
else { exit(EX_UNAVAILABLE) }

// Rediscovery can race the parent's timer. Never disconnect a device whose
// audio endpoint has already returned by the time this process starts.
let outputs: [OutputDevice]
do { outputs = try CoreAudioDeviceRepository().outputDevices() }
catch { exit(EX_IOERR) }
if outputs.contains(where: { BluetoothDeviceAddress.from(hardwareUID: $0.hardwareUID) == address }) {
  exit(EXIT_SUCCESS)
}

let closeStatus = device.closeConnection()
guard closeStatus == kIOReturnSuccess else { exit(EX_IOERR) }
let disconnectDeadline = Date().addingTimeInterval(2)
while device.isConnected(), Date() < disconnectDeadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard !device.isConnected() else { exit(EX_TEMPFAIL) }

// HCI page timeout units are 0.625 ms: 8000 units = 5 seconds.
let openStatus = device.openConnection(nil, withPageTimeout: 8000, authenticationRequired: false)
exit(openStatus == kIOReturnSuccess ? EXIT_SUCCESS : EX_IOERR)
