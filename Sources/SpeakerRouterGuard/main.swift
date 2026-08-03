import Darwin
import Foundation
import SpeakerRouterCore

private let timeout: TimeInterval = 10
private let pollIntervalMicroseconds: useconds_t = 500_000

private func argument(after name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name),
    CommandLine.arguments.indices.contains(index + 1)
  else {
    return nil
  }
  return CommandLine.arguments[index + 1]
}

private func processIsAlive(_ processID: pid_t) -> Bool {
  if kill(processID, 0) == 0 {
    return true
  }
  return errno == EPERM
}

private func restorePhysicalOutput(uid: String) -> Bool {
  let controller = CoreAudioSystemController()
  do {
    guard let deviceID = try controller.deviceID(forUID: uid) else {
      return false
    }
    try controller.setDefaultOutputs(to: deviceID)
    return true
  } catch {
    return false
  }
}

guard let parentString = argument(after: "--parent-pid"),
  let parentProcessID = pid_t(parentString),
  let heartbeatPath = argument(after: "--heartbeat")
else {
  exit(EX_USAGE)
}

let heartbeatURL = URL(fileURLWithPath: heartbeatPath)
let decoder = JSONDecoder()

while true {
  usleep(pollIntervalMicroseconds)

  guard let data = try? Data(contentsOf: heartbeatURL),
    let heartbeat = try? decoder.decode(GuardHeartbeat.self, from: data)
  else {
    if !processIsAlive(parentProcessID) {
      exit(EXIT_FAILURE)
    }
    continue
  }

  if heartbeat.cleanShutdown {
    exit(EXIT_SUCCESS)
  }

  let parentExited = !processIsAlive(parentProcessID)
  let heartbeatExpired = Date().timeIntervalSince(heartbeat.updatedAt) > timeout
  if parentExited || heartbeatExpired {
    exit(restorePhysicalOutput(uid: heartbeat.fallbackDeviceUID) ? EXIT_SUCCESS : EXIT_FAILURE)
  }
}
