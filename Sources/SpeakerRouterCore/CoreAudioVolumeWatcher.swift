import CoreAudio
import Dispatch
import Foundation

public struct OutputLevel: Equatable, Sendable {
  public let volume: Float
  public let isMuted: Bool

  public init(volume: Float, isMuted: Bool) {
    self.volume = volume
    self.isMuted = isMuted
  }
}

public enum CoreAudioVolumeWatcherError: Error, CustomStringConvertible, Sendable {
  case registration(OSStatus)

  public var description: String {
    switch self {
    case .registration(let status):
      "Register volume listener failed with Core Audio status \(status)"
    }
  }
}

public final class CoreAudioVolumeWatcher: @unchecked Sendable {
  public typealias Handler = @Sendable (OutputLevel) -> Void

  private let systemController: CoreAudioSystemController
  private let callbackQueue = DispatchQueue(label: "SpeakerRouter.volume-watcher")
  private let stateLock = NSLock()
  private var deviceID: AudioObjectID?
  private var listener: AudioObjectPropertyListenerBlock?
  private var handler: Handler?

  public init(systemController: CoreAudioSystemController = CoreAudioSystemController()) {
    self.systemController = systemController
  }

  deinit {
    stop()
  }

  public func start(deviceID: AudioObjectID, handler: @escaping Handler) throws {
    stop()

    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.publishLevel()
    }
    let addresses = propertyAddresses()
    for var address in addresses {
      let status = AudioObjectAddPropertyListenerBlock(
        deviceID,
        &address,
        callbackQueue,
        block
      )
      if status != noErr {
        for var registeredAddress in addresses {
          AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &registeredAddress,
            callbackQueue,
            block
          )
        }
        throw CoreAudioVolumeWatcherError.registration(status)
      }
    }

    stateLock.lock()
    self.deviceID = deviceID
    self.listener = block
    self.handler = handler
    stateLock.unlock()
    publishLevel()
  }

  public func stop() {
    stateLock.lock()
    let deviceID = deviceID
    let listener = listener
    self.deviceID = nil
    self.listener = nil
    handler = nil
    stateLock.unlock()

    guard let deviceID, let listener else { return }
    for var address in propertyAddresses() {
      AudioObjectRemovePropertyListenerBlock(
        deviceID,
        &address,
        callbackQueue,
        listener
      )
    }
  }

  private func publishLevel() {
    stateLock.lock()
    let deviceID = deviceID
    let handler = handler
    stateLock.unlock()
    guard let deviceID, let handler else { return }

    let volume = systemController.outputVolume(of: deviceID) ?? 0.3
    let muted = systemController.outputMute(of: deviceID)
    handler(OutputLevel(volume: volume, isMuted: muted))
  }

  private func propertyAddresses() -> [AudioObjectPropertyAddress] {
    [
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
      ),
    ]
  }
}
