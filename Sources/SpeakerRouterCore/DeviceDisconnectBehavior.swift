public enum DeviceDisconnectBehavior {
  public static func shouldPauseMedia(
    activeDeviceUID: String?,
    previousDevices: [OutputDevice],
    currentDevices: [OutputDevice]
  ) -> Bool {
    guard let activeDeviceUID,
      let disconnectedDevice = previousDevices.first(where: { $0.uid == activeDeviceUID }),
      disconnectedDevice.kind == .headphones
    else {
      return false
    }
    return !currentDevices.contains(where: { $0.uid == activeDeviceUID })
  }
}
