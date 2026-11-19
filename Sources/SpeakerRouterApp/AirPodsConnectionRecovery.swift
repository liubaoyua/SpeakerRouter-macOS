import Foundation
import IOBluetooth
import SpeakerRouterCore

@MainActor
final class AirPodsConnectionRecovery {
  private var process: Process?

  func isConnected(hardwareUID: String) -> Bool {
    guard let address = BluetoothDeviceAddress.from(hardwareUID: hardwareUID),
      let device = IOBluetoothDevice(addressString: address)
    else { return false }
    return device.isConnected()
  }

  func cancel() {
    if let process, process.isRunning { process.terminate() }
    process = nil
  }

  func reconnect(hardwareUID: String) async -> Bool {
    guard process == nil,
      let address = BluetoothDeviceAddress.from(hardwareUID: hardwareUID)
    else { return false }
    let helper = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/SpeakerRouterBluetoothRecovery"
    )
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { return false }
    let process = Process()
    process.executableURL = helper
    process.arguments = [address]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    self.process = process
    let deadline = Date().addingTimeInterval(12)
    while process.isRunning, Date() < deadline, !Task.isCancelled {
      do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
    }
    let completed = !process.isRunning
    if process.isRunning { process.terminate() }
    if self.process === process { self.process = nil }
    return completed && process.terminationStatus == 0 && !Task.isCancelled
  }
}
