import Foundation

public struct GuardHeartbeat: Codable, Equatable, Sendable {
  public let parentProcessID: Int32
  public let fallbackDeviceUID: String
  public let updatedAt: Date
  public let cleanShutdown: Bool

  public init(
    parentProcessID: Int32,
    fallbackDeviceUID: String,
    updatedAt: Date = Date(),
    cleanShutdown: Bool = false
  ) {
    self.parentProcessID = parentProcessID
    self.fallbackDeviceUID = fallbackDeviceUID
    self.updatedAt = updatedAt
    self.cleanShutdown = cleanShutdown
  }
}
