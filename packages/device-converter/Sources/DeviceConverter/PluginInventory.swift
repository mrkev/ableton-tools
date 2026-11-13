import Foundation

/// How a plugin device will behave in a native (Apple Silicon) Live.
enum PluginLoad: Equatable {
  /// A native build exists in the device's own format, so it loads as-is.
  case native
  /// Its VST2 build (or its AU, built around the VST2) isn't native, but a
  /// compatible native VST3 can replace it.
  case needsConversion(Vst3PluginInfo)
  /// Nothing native that Live could load in its place.
  case stuck(reason: String)
  /// Opted in: a different plugin replaces it (AMBEO Orbit → dearVR MICRO).
  case substitute(Substitution, PluginTarget)

  var needsWork: Bool {
    switch self {
    case .needsConversion, .substitute: return true
    case .native, .stuck: return false
    }
  }

  /// The work can't be done in a set saved before Live 10: it brings in a VST3.
  var needsLive10: Bool {
    switch self {
    case .needsConversion: return true
    case .substitute(let s, let target): return !s.worksBefore10(target)
    case .native, .stuck: return false
    }
  }
}

/// A plugin keeping a set from opening natively.
struct StuckPlugin: Hashable {
  let name: String
  let reason: String
}

/// What's installed, in every format, and which builds are native.
struct PluginInventory {
  /// Loadable in this (native) process.
  var vst3: [Vst3PluginInfo]
  /// Installed VST3 bundles, by normalized name, and whether each is native.
  var vst3Bundles: [String: Bool]
  /// Installed VST2 bundles, by lowercased file name, and whether each is native.
  var vst2Files: [String: Bool]
  var audioUnits: [AudioUnitInfo]
  /// Opted-in replacements of plugins by different ones.
  var substitutions: Set<Substitution> = []

  /// The opted-in, installed replacement for a device of `format` that `matches`.
  func substitution(for format: DeviceFormat, where matches: (Substitution) -> Bool) -> (Substitution, PluginTarget)? {
    for s in Substitution.allCases where substitutions.contains(s) && matches(s) {
      if let target = s.target(for: format, vst3: vst3, audioUnits: audioUnits) { return (s, target) }
    }
    return nil
  }

  func substitution(for device: Device) -> (Substitution, PluginTarget)? {
    substitution(for: device.format) { $0.matches(device) }
  }

  /// Doesn't load plugin code except for `vst3`, which needs the main thread.
  static func vst2Bundles() -> [String: Bool] {
    var out: [String: Bool] = [:]
    let home = FileManager.default.homeDirectoryForCurrentUser
    for dir in [URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST"),
                home.appendingPathComponent("Library/Audio/Plug-Ins/VST")] {
      for url in bundles(in: dir, withExtension: "vst") {
        out[url.lastPathComponent.lowercased()] = isNative(url)
      }
    }
    return out
  }

  static func vst3BundleArchitectures() -> [String: Bool] {
    var out: [String: Bool] = [:]
    for url in Vst3Catalog.bundles() {
      out[normalized(url.deletingPathExtension().lastPathComponent)] = isNative(url)
    }
    return out
  }

  /// Everything, synchronously. On the main thread, as `Vst3Catalog` requires.
  static func loadNow() -> PluginInventory {
    PluginInventory(
      vst3: Vst3Catalog.installed(), vst3Bundles: vst3BundleArchitectures(),
      vst2Files: vst2Bundles(), audioUnits: AudioUnitCatalog.installed())
  }

  private static func bundles(in dir: URL, withExtension ext: String) -> [URL] {
    guard let e = FileManager.default.enumerator(
      at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    var out: [URL] = []
    for case let url as URL in e where url.pathExtension == ext {
      out.append(url)
      e.skipDescendants()
    }
    return out
  }

  private static func isNative(_ bundle: URL) -> Bool {
    Bundle(url: bundle)?.executableArchitectures?
      .contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) == true
  }

  private static func normalized(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
  }

  // MARK: Single plugins

  /// `nil` when no VST2 build of it is installed.
  private func vst2IsNative(_ plugin: LiveSetScan.Vst2Plugin) -> Bool? {
    if let file = plugin.fileName?.lowercased(), let native = vst2Files[file] { return native }
    return vst2Files[plugin.name.lowercased() + ".vst"]
  }

  func isNative(_ plugin: LiveSetScan.Vst2Plugin) -> Bool { vst2IsNative(plugin) == true }

  func load(_ plugin: LiveSetScan.Vst2Plugin) -> PluginLoad {
    let vst2 = vst2IsNative(plugin)
    if vst2 == true { return .native }
    if let (s, target) = substitution(for: .vst, where: { $0.matches(plugin) }) { return .substitute(s, target) }
    switch Vst3Availability.resolve(plugin, catalog: vst3) {
    case .available(let target):
      return .needsConversion(target)
    case .unavailable(let why):
      var parts = [vst2 == nil ? "not installed" : "Intel only"]
      // Only worth saying when a VST3 exists but can't be used.
      if why != Vst3Availability.noVst3 { parts.append(why) }
      let lowered = plugin.name.lowercased()
      if audioUnits.contains(where: { $0.isNative && $0.name.lowercased() == lowered }) {
        parts.append("a native AU exists, but its settings wouldn't carry over")
      }
      return .stuck(reason: parts.joined(separator: "; "))
    }
  }

  func load(_ plugin: LiveSetScan.Vst3Plugin) -> PluginLoad {
    if plugin.uid.count == 4, vst3.contains(where: { $0.uidFields == plugin.uid }) { return .native }
    if let (s, target) = substitution(for: .vst3, where: { $0.matches(plugin) }) { return .substitute(s, target) }
    switch vst3Bundles[Self.normalized(plugin.name)] {
    case true?: return .stuck(reason: "installed VST3 is a different plugin ID")
    case false?: return .stuck(reason: "VST3 is Intel only")
    case nil: return .stuck(reason: "VST3 not installed")
    }
  }

  func load(_ plugin: LiveSetScan.AuPlugin) -> PluginLoad {
    let matches = audioUnits.filter {
      Int32(bitPattern: $0.typeCode) == plugin.type && Int32(bitPattern: $0.subTypeCode) == plugin.subType
        && Int32(bitPattern: $0.manufacturerCode) == plugin.manufacturer
    }
    if matches.contains(where: \.isNative) { return .native }
    if let (s, target) = substitution(for: .au, where: { $0.matches(plugin) }) { return .substitute(s, target) }
    if case .available(let target)? = Vst3Availability.resolve(plugin, catalog: vst3) {
      return .needsConversion(target)
    }
    return .stuck(reason: matches.isEmpty ? "AU not installed" : "AU is Intel only")
  }

  // MARK: Whole sets

  /// Every plugin device in the set, with how it loads.
  func loads(in scan: LiveSetScan) -> [(name: String, load: PluginLoad)] {
    scan.vst2.map { ($0.name, load($0)) } + scan.vst3.map { ($0.name, load($0)) }
      + scan.au.map { ($0.name, load($0)) }
  }

  func stuckPlugins(in scan: LiveSetScan) -> [StuckPlugin] {
    loads(in: scan).compactMap { name, load in
      if case .stuck(let reason) = load { return StuckPlugin(name: name, reason: reason) }
      return nil
    }
  }

  /// VST2 devices with a usable VST3, whether or not they need one to load, AUs
  /// that need their VST3, and opted-in substitutions.
  func convertibleCount(in scan: LiveSetScan) -> Int {
    scan.vst2.filter {
      if case .available = Vst3Availability.resolve($0, catalog: vst3) { return true }
      return false
    }.count + scan.au.filter {
      if case .needsConversion = load($0) { return true }
      return false
    }.count + substitutionCount(in: scan)
  }

  /// Devices an opted-in substitution replaces.
  func substitutionCount(in scan: LiveSetScan) -> Int {
    loads(in: scan).filter { if case .substitute = $0.load { return true } else { return false } }.count
  }

  /// Devices a substitution would replace, in any format.
  static func count(of s: Substitution, in scan: LiveSetScan) -> Int {
    scan.vst2.filter(s.matches).count + scan.vst3.filter(s.matches).count + scan.au.filter(s.matches).count
  }
}
