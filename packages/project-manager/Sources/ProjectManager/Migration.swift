import Foundation

/// The app was called Device Converter. Carries its settings and scan cache over
/// once, so the rename loses nothing.
enum LegacyMigration {
  static func run() {
    let defaults = UserDefaults.standard
    let bundled = Bundle.main.bundleIdentifier != nil
    let current = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    let legacy = bundled ? "dev.ableton-tools.device-converter" : "DeviceConverter"
    if defaults.persistentDomain(forName: current)?.isEmpty ?? true,
       let old = defaults.persistentDomain(forName: legacy), !old.isEmpty {
      defaults.setPersistentDomain(old, forName: current)
    }

    let fm = FileManager.default
    let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let oldCache = caches.appendingPathComponent("DeviceConverter")
    let newCache = caches.appendingPathComponent("ProjectManager")
    if !fm.fileExists(atPath: newCache.path), fm.fileExists(atPath: oldCache.path) {
      try? fm.moveItem(at: oldCache, to: newCache)
    }
  }
}
