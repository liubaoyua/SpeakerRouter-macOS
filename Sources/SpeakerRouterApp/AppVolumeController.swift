import AppKit
import CoreAudio
import SwiftUI
import SpeakerRouterCore

private struct AppVolumePreference: Codable, Equatable {
  var percent = 100
  var isMuted = false

  var gain: Float { isMuted ? 0 : Float(min(max(percent, 0), 200)) / 100 }
}

struct AppVolumeRow: Identifiable, Equatable {
  enum ID: Hashable {
    case bundle(String)
    case process(Int64)
  }

  let id: ID
  let name: String
  var percent: Int
  var isMuted: Bool
}

@MainActor
final class AppVolumeController: ObservableObject {
  @Published private(set) var rows: [AppVolumeRow] = []
  @Published private(set) var isUnavailable = false

  private static let defaultsKey = "appVolumePreferences"
  private let driver = AppVolumeDriver()
  private let defaults: UserDefaults
  private var saved: [String: AppVolumePreference]
  private var temporary: [Int64: AppVolumePreference] = [:]
  private var clients: [AppAudioClient] = []
  private var identities: [Int64: AudioAppIdentity] = [:]
  private var reportedGains: [Int64: Float] = [:]
  private var deviceID: AudioObjectID?
  private var routeGeneration = 0
  private var refreshPending = false
  private var applyPending = false
  private var isWorking = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    saved = defaults.data(forKey: Self.defaultsKey)
      .flatMap { try? JSONDecoder().decode([String: AppVolumePreference].self, from: $0) } ?? [:]
  }

  func attach(_ deviceID: AudioObjectID?) {
    guard self.deviceID != deviceID else { return }
    self.deviceID = deviceID
    routeGeneration += 1
    clients = []
    identities = [:]
    temporary = [:]
    reportedGains = [:]
    if !rows.isEmpty { rows = [] }
    if isUnavailable { isUnavailable = false }
    refresh()
  }

  func refresh() {
    guard deviceID != nil else { return }
    refreshPending = true
    work()
  }

  func setPercent(_ percent: Int, for id: AppVolumeRow.ID) {
    var preference = preference(for: id)
    preference.percent = min(max(percent, 0), 200)
    save(preference, for: id)
  }

  func toggleMute(for id: AppVolumeRow.ID) {
    var preference = preference(for: id)
    preference.isMuted.toggle()
    save(preference, for: id)
  }

  func reset(_ id: AppVolumeRow.ID) {
    save(AppVolumePreference(), for: id)
  }

  private func preference(for id: AppVolumeRow.ID) -> AppVolumePreference {
    switch id {
    case .bundle(let bundleID): saved[bundleID] ?? AppVolumePreference()
    case .process(let registration): temporary[registration] ?? AppVolumePreference()
    }
  }

  private func save(_ preference: AppVolumePreference, for id: AppVolumeRow.ID) {
    guard rows.contains(where: { $0.id == id }), preference != self.preference(for: id) else {
      return
    }
    let override = preference == AppVolumePreference() ? nil : preference
    switch id {
    case .bundle(let bundleID):
      saved[bundleID] = override
      if let data = try? JSONEncoder().encode(saved) {
        defaults.set(data, forKey: Self.defaultsKey)
      }
    case .process(let registration):
      temporary[registration] = override
    }
    publishRows()
    applyPending = true
    work()
  }

  private func work() {
    guard !isWorking, let deviceID, refreshPending || applyPending else { return }
    isWorking = true
    let generation = routeGeneration
    Task {
      defer {
        isWorking = false
        work()
      }

      if refreshPending {
        refreshPending = false
        do {
          let snapshot = try await driver.snapshot(deviceID: deviceID)
          guard generation == routeGeneration else { return }
          accept(snapshot)
          applyPending = true
        } catch {
          guard generation == routeGeneration else { return }
          if !isUnavailable { isUnavailable = true }
          return
        }
      }

      guard generation == routeGeneration, applyPending else { return }
      applyPending = false
      var changes: [Int64: Float] = [:]
      for client in clients {
        let id = identities[client.registration]?.id ?? .process(client.registration)
        let gain = preference(for: id).gain
        if reportedGains[client.registration] != gain {
          changes[client.registration] = gain
        }
      }
      do {
        if !changes.isEmpty {
          try await driver.setTargets(changes, deviceID: deviceID)
          guard generation == routeGeneration else { return }
          reportedGains.merge(changes) { _, current in current }
        }
        if isUnavailable { isUnavailable = false }
      } catch {
        guard generation == routeGeneration else { return }
        if !isUnavailable { isUnavailable = true }
      }
    }
  }

  private func accept(_ snapshot: [AppAudioClient]) {
    clients = snapshot
    let registrations = Set(snapshot.map(\.registration))
    identities = identities.filter { registrations.contains($0.key) }
    temporary = temporary.filter { registrations.contains($0.key) }
    reportedGains = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.registration, $0.targetGain) })
    for client in snapshot where identities[client.registration]?.isResolved != true {
      identities[client.registration] = AudioAppIdentity.resolve(client)
    }
    publishRows()
  }

  private func publishRows() {
    var unique: [AppVolumeRow.ID: AppVolumeRow] = [:]
    for client in clients where client.isActive {
      guard let identity = identities[client.registration], unique[identity.id] == nil else {
        continue
      }
      let preference = preference(for: identity.id)
      unique[identity.id] = AppVolumeRow(
        id: identity.id, name: identity.name, percent: preference.percent,
        isMuted: preference.isMuted
      )
    }
    let updated = unique.values.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? String(describing: $0.id) < String(describing: $1.id)
        : order == .orderedAscending
    }
    if rows != updated { rows = updated }
  }
}

private struct AudioAppIdentity {
  let id: AppVolumeRow.ID
  let name: String

  var isResolved: Bool {
    if case .bundle = id { return true }
    return false
  }

  // Dynamically resolve the non-public PID lookup. Some XPC helpers are launched
  // by launchd, so the Unix parent PID and the shared WebKit bundle ID are ambiguous.
  private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
      "responsibility_get_pid_responsible_for_pid")
    else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
  }()

  @MainActor
  static func resolve(_ client: AppAudioClient) -> Self {
    let process = NSRunningApplication(processIdentifier: client.pid)
    if let identity = appIdentity(process) { return identity }

    if let owner = responsiblePID?(client.pid), owner > 1, owner != client.pid,
      let identity = appIdentity(NSRunningApplication(processIdentifier: owner))
    {
      return identity
    }

    // Embedded helpers can also be attributed by their path inside a running App.
    var path = [CChar](repeating: 0, count: 4096)
    let length = path.withUnsafeMutableBytes { proc_pidpath(client.pid, $0.baseAddress, UInt32($0.count)) }
    let executable = length > 0
      ? String(decoding: path.prefix(Int(length)).prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
        as: UTF8.self)
      : process?.executableURL?.path
    if let executable {
      let owner = NSWorkspace.shared.runningApplications
        .filter { app in
          guard let root = app.bundleURL?.path else { return false }
          return executable.hasPrefix(root + "/Contents/") && appIdentity(app) != nil
        }
        .max { ($0.bundleURL?.path.count ?? 0) < ($1.bundleURL?.path.count ?? 0) }
      if let identity = appIdentity(owner) { return identity }
    }

    // Leave unidentified services separate, even if their HAL bundle IDs match.
    let label = process?.localizedName
      ?? executable.map { URL(fileURLWithPath: $0).lastPathComponent }
      ?? (client.bundleID.isEmpty ? "音频进程" : client.bundleID)
    return Self(id: .process(client.registration), name: "\(label)（PID \(client.pid)）")
  }

  @MainActor
  private static func appIdentity(_ app: NSRunningApplication?) -> Self? {
    guard let app, let bundleID = app.bundleIdentifier,
      !bundleID.hasPrefix("com.apple.WebKit."),
      let url = app.bundleURL, url.pathExtension == "app",
      !url.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".app") })
    else { return nil }
    return Self(id: .bundle(bundleID), name: app.localizedName ?? bundleID)
  }
}
