import Darwin

final class MediaPauseController {
  private typealias SendCommand = @convention(c) (UInt32, UnsafeRawPointer?) -> UInt8

  private let frameworkHandle: UnsafeMutableRawPointer?
  private let sendCommand: SendCommand?

  init() {
    let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
    else {
      frameworkHandle = nil
      sendCommand = nil
      return
    }
    frameworkHandle = handle
    sendCommand = dlsym(handle, "MRMediaRemoteSendCommand").map {
      unsafeBitCast($0, to: SendCommand.self)
    }
  }

  deinit {
    if let frameworkHandle {
      dlclose(frameworkHandle)
    }
  }

  @discardableResult
  func pause() -> Bool {
    // MediaRemote command 1 is an idempotent Pause, not a play/pause toggle. Dynamic loading
    // keeps failure harmless on systems where the private framework is unavailable.
    sendCommand?(1, nil) != 0
  }

  @discardableResult
  func play() -> Bool {
    // MediaRemote command 0 is an explicit Play command.
    sendCommand?(0, nil) != 0
  }
}
