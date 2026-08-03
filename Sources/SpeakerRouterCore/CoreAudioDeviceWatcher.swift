import CoreAudio
import Dispatch
import Foundation

public enum CoreAudioDeviceWatcherError: Error {
  case listenerRegistration(OSStatus)
}

public final class CoreAudioDeviceWatcher: @unchecked Sendable {
  public typealias Handler = @Sendable (Result<[OutputDevice], Error>) -> Void

  private struct DeviceListener {
    let block: AudioObjectPropertyListenerBlock
    let addresses: [AudioObjectPropertyAddress]
  }

  private let repository: CoreAudioDeviceRepository
  private let callbackQueue = DispatchQueue(label: "SpeakerRouter.device-watcher")
  private let stateLock = NSLock()
  private var systemListener: AudioObjectPropertyListenerBlock?
  private var deviceListeners: [AudioObjectID: DeviceListener] = [:]
  private var handler: Handler?

  public init(repository: CoreAudioDeviceRepository = CoreAudioDeviceRepository()) {
    self.repository = repository
  }

  deinit {
    stop()
  }

  public func start(handler: @escaping Handler) throws {
    stateLock.lock()
    guard systemListener == nil else {
      stateLock.unlock()
      return
    }
    self.handler = handler
    stateLock.unlock()

    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.deviceListChanged()
    }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      callbackQueue,
      block
    )
    guard status == noErr else {
      stateLock.lock()
      self.handler = nil
      stateLock.unlock()
      throw CoreAudioDeviceWatcherError.listenerRegistration(status)
    }

    stateLock.lock()
    systemListener = block
    stateLock.unlock()
    callbackQueue.async { [weak self] in
      self?.rebuildDeviceListeners()
    }
  }

  public func stop() {
    stateLock.lock()
    let systemListener = systemListener
    let deviceListeners = deviceListeners
    self.systemListener = nil
    self.deviceListeners = [:]
    handler = nil
    stateLock.unlock()

    if let systemListener {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        callbackQueue,
        systemListener
      )
    }

    for (deviceID, listener) in deviceListeners {
      for var address in listener.addresses {
        AudioObjectRemovePropertyListenerBlock(
          deviceID,
          &address,
          callbackQueue,
          listener.block
        )
      }
    }
  }

  private func deviceListChanged() {
    rebuildDeviceListeners()
    publishSnapshot()
  }

  private func rebuildDeviceListeners() {
    guard let devices = try? repository.outputDevices() else { return }
    let liveIDs = Set(devices.map(\.objectID))

    stateLock.lock()
    let existingListeners = deviceListeners
    stateLock.unlock()

    for (deviceID, listener) in existingListeners where !liveIDs.contains(deviceID) {
      for var address in listener.addresses {
        AudioObjectRemovePropertyListenerBlock(
          deviceID,
          &address,
          callbackQueue,
          listener.block
        )
      }
      stateLock.lock()
      deviceListeners.removeValue(forKey: deviceID)
      stateLock.unlock()
    }

    for device in devices where existingListeners[device.objectID] == nil {
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.publishSnapshot()
      }
      var registeredAddresses: [AudioObjectPropertyAddress] = []
      for var address in watchedDeviceAddresses() {
        guard AudioObjectHasProperty(device.objectID, &address) else { continue }
        let status = AudioObjectAddPropertyListenerBlock(
          device.objectID,
          &address,
          callbackQueue,
          block
        )
        if status == noErr {
          registeredAddresses.append(address)
        }
      }
      guard !registeredAddresses.isEmpty else { continue }
      stateLock.lock()
      deviceListeners[device.objectID] = DeviceListener(
        block: block,
        addresses: registeredAddresses
      )
      stateLock.unlock()
    }
  }

  private func publishSnapshot() {
    let result = Result { try repository.outputDevices() }
    stateLock.lock()
    let handler = handler
    stateLock.unlock()
    handler?(result)
  }

  private func watchedDeviceAddresses() -> [AudioObjectPropertyAddress] {
    [
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
    ]
  }
}
