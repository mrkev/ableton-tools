// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DeviceConverter",
  platforms: [.macOS(.v14)],
  targets: [
    // Thin C shim over the system zlib for gzip (de)compression of .als files.
    .target(
      name: "CGzip",
      linkerSettings: [.linkedLibrary("z")]
    ),
    // Minimal offline VST3 host (load bundle, push/pull state, list params).
    .target(
      name: "CVst3Host",
      linkerSettings: [.linkedFramework("CoreFoundation")]
    ),
    .executableTarget(
      name: "DeviceConverter",
      dependencies: ["CGzip", "CVst3Host"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
