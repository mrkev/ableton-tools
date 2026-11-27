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
  /// Its only build is x86-64: it loads when Live runs under Rosetta.
  var rosetta = false
}

/// What's installed, in every format, and which builds are native.
/// The most capable code an installed plugin bundle has.
enum PluginArchitecture: Int, Comparable, Hashable, Sendable {
  /// arm64: a native Live loads it.
  case native
  /// x86-64 only: a Live running under Rosetta loads it.
  case x86_64
  /// Neither: in practice 32-bit, which no Mac runs since Catalina, Rosetta
  /// included, and which no 64-bit Live (10 and later) could load anyway.
  case bit32

  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  init(_ architectures: [NSNumber]?) {
    let archs = Set((architectures ?? []).map(\.intValue))
    if archs.contains(NSBundleExecutableArchitectureARM64) {
      self = .native
    } else if archs.contains(NSBundleExecutableArchitectureX86_64) {
      self = .x86_64
    } else {
      self = .bit32
    }
  }

  init(bundle: URL) { self.init(Bundle(url: bundle)?.executableArchitectures) }

  /// For a table: "Native (arm64)", "x86-64", "32-bit".
  var title: String {
    switch self {
    case .native: return "Native (arm64)"
    case .x86_64: return "x86-64"
    case .bit32: return "32-bit"
    }
  }

  /// For a plugin's stuck reason: "Intel only", "32-bit only".
  var only: String { self == .bit32 ? "32-bit only" : "Intel only" }
}

/// An installed plugin: where it is and what it runs on.
struct InstalledPlugin: Hashable, Sendable {
  /// `nil` for an Audio Unit the system reports no bundle for (an app extension).
  let url: URL?
  let architecture: PluginArchitecture
}

/// What a set needs to load fully, as saved: the least capable plugin decides.
/// Only Native and x86-64 sets load anywhere.
enum SetArchitecture: Int, Comparable {
  case native, x86_64, bit32, notInstalled

  static func < (a: SetArchitecture, b: SetArchitecture) -> Bool { a.rawValue < b.rawValue }

  init(_ architecture: PluginArchitecture?) {
    switch architecture {
    case .native?: self = .native
    case .x86_64?: self = .x86_64
    case .bit32?: self = .bit32
    case nil: self = .notInstalled
    }
  }

  var title: String {
    switch self {
    case .native: return "Native"
    case .x86_64: return "x86-64"
    case .bit32: return "32-bit"
    case .notInstalled: return "Not Installed"
    }
  }

  var explanation: String {
    switch self {
    case .native: return "Every plugin has an Apple Silicon build."
    case .x86_64: return "Some plugins are Intel only: Live loads them running under Rosetta."
    case .bit32: return "Some plugins are 32-bit only, which no current Mac or Live can load."
    case .notInstalled: return "Some plugins aren't installed."
    }
  }
}

struct PluginInventory {
  /// Loadable in this (native) process.
  var vst3: [Vst3PluginInfo]
  /// Installed VST3 bundles, by normalized name.
  var vst3Bundles: [String: InstalledPlugin]
  /// Installed VST2 bundles, by lowercased file name.
  var vst2Files: [String: InstalledPlugin]
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
  static func vst2Bundles() -> [String: InstalledPlugin] {
    var out: [String: InstalledPlugin] = [:]
    let home = FileManager.default.homeDirectoryForCurrentUser
    for dir in [URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST"),
                home.appendingPathComponent("Library/Audio/Plug-Ins/VST")] {
      for url in bundles(in: dir, withExtension: "vst") {
        out[url.lastPathComponent.lowercased()] = InstalledPlugin(url: url, architecture: PluginArchitecture(bundle: url))
      }
    }
    return out
  }

  static func vst3BundleArchitectures() -> [String: InstalledPlugin] {
    var out: [String: InstalledPlugin] = [:]
    for url in Vst3Catalog.bundles() {
      out[normalized(url.deletingPathExtension().lastPathComponent)] =
        InstalledPlugin(url: url, architecture: PluginArchitecture(bundle: url))
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

  private static func normalized(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
  }

  // MARK: Single plugins

  /// The plugin's own installed build, in the format the set uses; `nil` when none is.
  func installed(_ plugin: LiveSetScan.Vst2Plugin) -> InstalledPlugin? {
    if let file = plugin.fileName?.lowercased(), let found = vst2Files[file] { return found }
    return vst2Files[plugin.name.lowercased() + ".vst"]
  }

  /// The VST3 bundle of that name.
  func installed(_ plugin: LiveSetScan.Vst3Plugin) -> InstalledPlugin? {
    vst3Bundles[Self.normalized(plugin.name)]
  }

  /// The best build among the Audio Units with its codes.
  func installed(_ plugin: LiveSetScan.AuPlugin) -> InstalledPlugin? {
    audioUnits.filter {
      Int32(bitPattern: $0.typeCode) == plugin.type && Int32(bitPattern: $0.subTypeCode) == plugin.subType
        && Int32(bitPattern: $0.manufacturerCode) == plugin.manufacturer
    }
    .min { $0.architecture < $1.architecture }
    .map { InstalledPlugin(url: $0.url, architecture: $0.architecture) }
  }

  private func architecture(_ plugin: LiveSetScan.Vst2Plugin) -> PluginArchitecture? { installed(plugin)?.architecture }
  private func architecture(_ plugin: LiveSetScan.Vst3Plugin) -> PluginArchitecture? { installed(plugin)?.architecture }
  private func architecture(_ plugin: LiveSetScan.AuPlugin) -> PluginArchitecture? { installed(plugin)?.architecture }

  func load(_ plugin: LiveSetScan.Vst2Plugin) -> PluginLoad {
    let vst2 = architecture(plugin)
    if vst2 == .native { return .native }
    if let (s, target) = substitution(for: .vst, where: { $0.matches(plugin) }) { return .substitute(s, target) }
    switch Vst3Availability.resolve(plugin, catalog: vst3) {
    case .available(let target):
      return .needsConversion(target)
    case .unavailable(let why):
      var parts = [vst2?.only ?? "not installed"]
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
    switch architecture(plugin) {
    case .native?: return .stuck(reason: "installed VST3 is a different plugin ID")
    case let other?: return .stuck(reason: "VST3 is \(other.only)")
    case nil: return .stuck(reason: "VST3 not installed")
    }
  }

  func load(_ plugin: LiveSetScan.AuPlugin) -> PluginLoad {
    let installed = architecture(plugin)
    if installed == .native { return .native }
    if let (s, target) = substitution(for: .au, where: { $0.matches(plugin) }) { return .substitute(s, target) }
    if case .available(let target)? = Vst3Availability.resolve(plugin, catalog: vst3) {
      return .needsConversion(target)
    }
    return .stuck(reason: installed.map { "AU is \($0.only)" } ?? "AU not installed")
  }

  /// How a device in an open set loads; `nil` for Live's own devices.
  func load(_ device: Device) -> PluginLoad? {
    switch device.format {
    case .vst:
      let type = Vst2State.presetType(device.element)
      let info = device.element.firstChild("PluginDesc")?.firstChild("VstPluginInfo")
      return load(LiveSetScan.Vst2Plugin(
        name: device.product, uniqueId: Vst3Migration.vst2UniqueId(device), isChunk: type == "FBCh",
        isParameterDump: type == "FxBk", fileName: info?.childValue("FileName")))
    case .vst3:
      return load(LiveSetScan.Vst3Plugin(name: device.product, uid: device.vst3Uid ?? []))
    case .au:
      return LiveSetScan.AuPlugin(device: device).map { load($0) }
    case .native, .m4l:
      return nil
    }
  }

  /// The installed build of a device's plugin, in the device's format.
  func installed(_ device: Device) -> InstalledPlugin? {
    switch device.format {
    case .vst:
      let info = device.element.firstChild("PluginDesc")?.firstChild("VstPluginInfo")
      return installed(LiveSetScan.Vst2Plugin(
        name: device.product, uniqueId: Vst3Migration.vst2UniqueId(device), isChunk: false,
        fileName: info?.childValue("FileName")))
    case .vst3:
      return installed(LiveSetScan.Vst3Plugin(name: device.product, uid: device.vst3Uid ?? []))
    case .au:
      return LiveSetScan.AuPlugin(device: device).flatMap { installed($0) }
    case .native, .m4l:
      return nil
    }
  }

  // MARK: Whole sets

  /// Every plugin device in the set, with how it loads.
  func loads(in scan: LiveSetScan) -> [(name: String, load: PluginLoad)] {
    scan.vst2.map { ($0.name, load($0)) } + scan.vst3.map { ($0.name, load($0)) }
      + scan.au.map { ($0.name, load($0)) }
  }

  /// Which Live a set's plugins load in as saved, before any fixing: the least
  /// capable build among them decides.
  func architecture(of scan: LiveSetScan) -> SetArchitecture {
    let builds = scan.vst2.map(build) + scan.vst3.map(build) + scan.au.map(build)
    return builds.max() ?? .native
  }

  /// The best build installed in the device's own format.
  private func build(_ plugin: LiveSetScan.Vst2Plugin) -> SetArchitecture { SetArchitecture(architecture(plugin)) }

  private func build(_ plugin: LiveSetScan.Vst3Plugin) -> SetArchitecture {
    if load(plugin) == .native { return .native }
    // A native bundle that didn't match has a different plugin ID: it won't load anywhere.
    let found = architecture(plugin)
    return found == .native ? .notInstalled : SetArchitecture(found)
  }

  private func build(_ plugin: LiveSetScan.AuPlugin) -> SetArchitecture { SetArchitecture(architecture(plugin)) }

  /// Plugins with nothing native to load or convert to, and whether each has an
  /// Intel build that loads under Rosetta.
  func stuckPlugins(in scan: LiveSetScan) -> [StuckPlugin] {
    func stuck(_ name: String, _ load: PluginLoad, _ installed: InstalledPlugin?) -> StuckPlugin? {
      guard case .stuck(let reason) = load else { return nil }
      return StuckPlugin(name: name, reason: reason, rosetta: installed?.architecture == .x86_64)
    }
    return scan.vst2.compactMap { stuck($0.name, load($0), installed($0)) }
      + scan.vst3.compactMap { stuck($0.name, load($0), installed($0)) }
      + scan.au.compactMap { stuck($0.name, load($0), installed($0)) }
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
