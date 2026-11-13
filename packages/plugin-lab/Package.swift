// swift-tools-version: 6.0
import PackageDescription

// Offline tools for studying audio plugins: host them, render through them, and
// compare the results. Build for x86_64 too, so Intel-only plugins load under
// Rosetta (see README).
let package = Package(
  name: "PluginLab",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "auhost",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
