// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SpeakerRouter",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "SpeakerRouterCore", targets: ["SpeakerRouterCore"]),
    .executable(name: "SpeakerRouterApp", targets: ["SpeakerRouterApp"]),
    .executable(name: "SpeakerRouterGuard", targets: ["SpeakerRouterGuard"]),
  ],
  targets: [
    .target(
      name: "SpeakerRouterAudioSupport",
      publicHeadersPath: "include"
    ),
    .target(
      name: "SpeakerRouterCore",
      dependencies: ["SpeakerRouterAudioSupport"],
      linkerSettings: [
        .linkedFramework("CoreAudio")
      ]
    ),
    .executableTarget(
      name: "SpeakerRouterApp",
      dependencies: ["SpeakerRouterCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreAudio"),
      ]
    ),
    .executableTarget(
      name: "SpeakerRouterGuard",
      dependencies: ["SpeakerRouterCore"]
    ),
    .testTarget(
      name: "SpeakerRouterCoreTests",
      dependencies: ["SpeakerRouterCore", "SpeakerRouterAudioSupport"]
    ),
  ]
)
