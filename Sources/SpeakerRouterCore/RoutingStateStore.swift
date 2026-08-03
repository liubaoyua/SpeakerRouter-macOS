import Foundation

public protocol RoutingStateStore {
  func load() throws -> RoutingState
  func save(_ state: RoutingState) throws
}

public struct FileRoutingStateStore: RoutingStateStore {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> RoutingState {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return RoutingState()
    }
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(RoutingState.self, from: data)
  }

  public func save(_ state: RoutingState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: fileURL, options: .atomic)
  }
}
