import CoreBluetooth
import Foundation
import SpeakerRouterCore

final class AirPodsWearMonitor: NSObject, CBCentralManagerDelegate {
  private let onWearStateChanged: @MainActor (AirPodsWearState) -> Void
  private var centralManager: CBCentralManager?
  private var targetName: String?
  private var lastWearState: AirPodsWearState?

  init(onWearStateChanged: @escaping @MainActor (AirPodsWearState) -> Void) {
    self.onWearStateChanged = onWearStateChanged
    super.init()
  }

  func start(deviceName: String) {
    let normalizedName = Self.normalized(deviceName)
    guard normalizedName.contains("airpods") else {
      stop()
      return
    }
    guard targetName != normalizedName else { return }

    targetName = normalizedName
    lastWearState = nil
    if let centralManager {
      startScanningIfPossible(centralManager)
    } else {
      centralManager = CBCentralManager(delegate: self, queue: .main)
    }
  }

  func stop() {
    targetName = nil
    lastWearState = nil
    centralManager?.stopScan()
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
      ),
      wearState != lastWearState
    else {
      return
    }

    lastWearState = wearState
    Task { @MainActor [onWearStateChanged] in
      onWearStateChanged(wearState)
    }
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
}
