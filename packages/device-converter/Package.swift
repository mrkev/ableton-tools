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
    .executableTarget(
      name: "DeviceConverter",
      dependencies: ["CGzip"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
