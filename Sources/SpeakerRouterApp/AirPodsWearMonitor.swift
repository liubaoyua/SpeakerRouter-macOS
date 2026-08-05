import CoreBluetooth
import Foundation
import SpeakerRouterCore

final class AirPodsWearMonitor: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
  private struct LogEvent: Decodable {
    let eventMessage: String
  }

  private let onWearStateChanged: @MainActor (AirPodsWearState) -> Void
  private var centralManager: CBCentralManager?
  private var logProcess: Process?
  private var logOutputBuffer = Data()
  private var targetName: String?
  private var targetAddress: String?
  private var lastWearState: AirPodsWearState?

  init(onWearStateChanged: @escaping @MainActor (AirPodsWearState) -> Void) {
    self.onWearStateChanged = onWearStateChanged
    super.init()
  }

  func start(deviceName: String, hardwareUID: String) {
    let normalizedName = Self.normalized(deviceName)
    guard normalizedName.contains("airpods") else {
      stop()
      return
    }
    let address = Self.bluetoothAddress(from: hardwareUID)
    guard targetName != normalizedName || targetAddress != address else { return }

    targetName = normalizedName
    targetAddress = address
    let baseline = AirPodsWearState(primaryInEar: true, secondaryInEar: true)
    lastWearState = baseline
    Task { @MainActor [onWearStateChanged] in
      onWearStateChanged(baseline)
    }
    startPlacementLogMonitoring()
    if let centralManager {
      startScanningIfPossible(centralManager)
    } else {
      centralManager = CBCentralManager(delegate: self, queue: .main)
    }
  }

  func stop() {
    targetName = nil
    targetAddress = nil
    lastWearState = nil
    centralManager?.stopScan()
    stopPlacementLogMonitoring()
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    startScanningIfPossible(central)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard let targetName,
      Self.advertisedNames(peripheral: peripheral, data: advertisementData)
        .contains(targetName),
      let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey]
        as? Data,
      let wearState = AirPodsProximityAdvertisement.wearState(
        from: manufacturerData
      )
    else {
      return
    }
    publish(wearState)
  }

  private func startScanningIfPossible(_ central: CBCentralManager) {
    guard targetName != nil, central.state == .poweredOn else {
      central.stopScan()
      return
    }
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
  }

  private func startPlacementLogMonitoring() {
    stopPlacementLogMonitoring()
    guard let targetAddress else { return }

    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let predicate =
      "process == \"bluetoothd\" AND subsystem == \"com.apple.bluetooth\" "
      + "AND category == \"Server.AACP\" "
      + "AND eventMessage CONTAINS \"received in-ear state update\" "
      + "AND eventMessage CONTAINS[c] \"" + targetAddress + "\""
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "stream",
      "--style", "ndjson",
      "--level", "default",
      "--predicate", predicate,
    ]
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      Task { @MainActor [weak self] in
        self?.consumeLogOutput(data)
      }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      if handle.availableData.isEmpty {
        handle.readabilityHandler = nil
      }
    }
    process.terminationHandler = { [weak self, weak process] _ in
      Task { @MainActor [weak self, weak process] in
        guard let self, let process, self.logProcess === process else { return }
        self.logProcess = nil
      }
    }

    do {
      try process.run()
      logProcess = process
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
    }
  }

  private func stopPlacementLogMonitoring() {
    if let pipe = logProcess?.standardOutput as? Pipe {
      pipe.fileHandleForReading.readabilityHandler = nil
    }
    if let pipe = logProcess?.standardError as? Pipe {
      pipe.fileHandleForReading.readabilityHandler = nil
    }
    logProcess?.terminationHandler = nil
    logProcess?.terminate()
    logProcess = nil
    logOutputBuffer.removeAll(keepingCapacity: false)
  }

  private func consumeLogOutput(_ data: Data) {
    logOutputBuffer.append(data)
    while let newline = logOutputBuffer.firstIndex(of: 0x0A) {
      let line = logOutputBuffer[..<newline]
      logOutputBuffer.removeSubrange(...newline)
      guard !line.isEmpty,
        let event = try? JSONDecoder().decode(LogEvent.self, from: Data(line)),
        let targetAddress,
        let wearState = AirPodsPlacementLogParser.wearState(
          from: event.eventMessage,
          targetAddress: targetAddress
        )
      else {
        continue
      }
      publish(wearState)
    }
  }

  private func publish(_ wearState: AirPodsWearState) {
    guard targetName != nil, wearState != lastWearState else { return }
    lastWearState = wearState
    Task { @MainActor [onWearStateChanged] in
      onWearStateChanged(wearState)
    }
  }

  private static func advertisedNames(
    peripheral: CBPeripheral,
    data: [String: Any]
  ) -> Set<String> {
    var names = Set<String>()
    if let name = peripheral.name {
      names.insert(normalized(name))
    }
    if let name = data[CBAdvertisementDataLocalNameKey] as? String {
      names.insert(normalized(name))
    }
    return names
  }

  private static func normalized(_ name: String) -> String {
    String(name.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  private static func bluetoothAddress(from hardwareUID: String) -> String? {
    let components = hardwareUID
      .uppercased()
      .replacingOccurrences(of: ":", with: "-")
      .split(separator: "-")
    guard components.count >= 6 else { return nil }
    let addressComponents = components.prefix(6)
    guard addressComponents.allSatisfy({
      $0.count == 2 && $0.allSatisfy(\.isHexDigit)
    }) else {
      return nil
    }
    return addressComponents.joined(separator: ":")
  }
}
