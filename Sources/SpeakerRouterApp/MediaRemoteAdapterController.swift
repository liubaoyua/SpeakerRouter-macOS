import Foundation

@MainActor
final class MediaRemoteAdapterController {
  private struct StreamEvent: Decodable {
    struct Payload: Decodable {
      let playing: Bool?
    }

    let payload: Payload
  }

  private let onPlayingChanged: (Bool?) -> Void
  private var listenerProcess: Process?
  private var commandProcesses: [Process] = []
  private var outputBuffer = Data()
  private var hasPublishedState = false

  private(set) var isFunctional = false
  private(set) var isPlaying: Bool?

  init(onPlayingChanged: @escaping (Bool?) -> Void) {
    self.onPlayingChanged = onPlayingChanged
  }

  func start() {
    guard listenerProcess == nil,
      let resources = bundledResources()
    else {
      return
    }

    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
      resources.script.path,
      resources.framework.path,
      "stream",
      "--no-diff",
      "--debounce=50",
      "--no-artwork",
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
        self?.consume(data)
      }
    }
    // Adapter diagnostics are non-fatal unless the process exits. Drain stderr so a
    // long-running listener can never block on a full pipe.
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      if handle.availableData.isEmpty {
        handle.readabilityHandler = nil
      }
    }
    process.terminationHandler = { [weak self, weak process] _ in
      Task { @MainActor [weak self, weak process] in
        guard let self, let process, self.listenerProcess === process else { return }
        self.listenerProcess = nil
        self.markUnavailable()
      }
    }

    do {
      try process.run()
      listenerProcess = process
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      markUnavailable()
    }
  }

  func stop() {
    if let outputPipe = listenerProcess?.standardOutput as? Pipe {
      outputPipe.fileHandleForReading.readabilityHandler = nil
    }
    if let errorPipe = listenerProcess?.standardError as? Pipe {
      errorPipe.fileHandleForReading.readabilityHandler = nil
    }
    listenerProcess?.terminationHandler = nil
    listenerProcess?.terminate()
    listenerProcess = nil

    for process in commandProcesses where process.isRunning {
      process.terminate()
    }
    commandProcesses.removeAll()
    outputBuffer.removeAll(keepingCapacity: false)
    hasPublishedState = false
    markUnavailable()
  }

  @discardableResult
  func pause() -> Bool {
    send(commandID: 1)
  }

  @discardableResult
  func play() -> Bool {
    send(commandID: 0)
  }

  private func send(commandID: Int) -> Bool {
    guard isFunctional, let resources = bundledResources() else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
      resources.script.path,
      resources.framework.path,
      "send",
      String(commandID),
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self, weak process] _ in
      Task { @MainActor [weak self, weak process] in
        guard let self, let process else { return }
        self.commandProcesses.removeAll { $0 === process }
      }
    }

    do {
      try process.run()
      commandProcesses.append(process)
      return true
    } catch {
      return false
    }
  }

  private func consume(_ data: Data) {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let line = outputBuffer[..<newline]
      outputBuffer.removeSubrange(...newline)
      guard !line.isEmpty,
        let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(line))
      else {
        continue
      }

      let previous = isPlaying
      isFunctional = true
      isPlaying = event.payload.playing
      if !hasPublishedState || previous != isPlaying {
        hasPublishedState = true
        onPlayingChanged(isPlaying)
      }
    }
  }

  private func markUnavailable() {
    let shouldPublish = isFunctional || isPlaying != nil || hasPublishedState
    isFunctional = false
    isPlaying = nil
    if shouldPublish {
      onPlayingChanged(nil)
    }
  }

  private func bundledResources() -> (script: URL, framework: URL)? {
    guard let resourceURL = Bundle.main.resourceURL,
      let frameworksURL = Bundle.main.privateFrameworksURL
    else {
      return nil
    }
    let script =
      resourceURL
      .appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
      .appendingPathComponent("mediaremote-adapter.pl")
    let framework = frameworksURL.appendingPathComponent(
      "MediaRemoteAdapter.framework",
      isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: script.path),
      FileManager.default.fileExists(atPath: framework.path)
    else {
      return nil
    }
    return (script, framework)
  }
}
