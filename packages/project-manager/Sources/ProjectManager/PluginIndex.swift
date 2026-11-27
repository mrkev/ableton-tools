import Foundation

/// What a plugin needs to work in a native Live, before any per-set choice.
enum PluginVerdict: Hashable {
  case native
  /// Its own VST3, which is native, replaces it, keeping its settings. The VST3
  /// is matched by the VST2 unique id it declares it replaces, so it's the same
  /// plugin.
  case converts
  /// A different plugin can stand in for it (`Substitution`).
  case replaceable(Substitution)
  /// Only an Intel (x86-64) build: it loads when Live runs under Rosetta.
  case rosettaOnly
  /// Loads in no Live: 32-bit, not installed, or a VST3 with a different id.
  case stuck(String)

  /// Most in need of attention first.
  var rank: Int {
    switch self {
    case .stuck: return 0
    case .rosettaOnly: return 1
    case .replaceable: return 2
    case .converts: return 3
    case .native: return 4
    }
  }

  /// Keeps the sets using it from opening fully in a native Live, with nothing
  /// that fixes it automatically.
  var holdsBack: Bool { rank < 3 }

  var title: String {
    switch self {
    case .native: return "Native"
    case .converts: return "Converts to native (VST3)"
    case .replaceable(let s): return "Can be replaced with \(s.targetName)"
    case .rosettaOnly: return "Rosetta only"
    case .stuck: return "Won't load"
    }
  }

  var detail: String? {
    switch self {
    case .stuck(let why): return why
    case .rosettaOnly: return "loads when Live runs under Rosetta"
    case .replaceable(let s): return s.outcome
    case .converts: return "keeps its settings"
    case .native: return nil
    }
  }

  init(load: PluginLoad, substitution: Substitution?, installed: InstalledPlugin?) {
    switch load {
    case .native: self = .native
    case .needsConversion: self = .converts
    case .substitute(let s, _): self = .replaceable(s)
    case .stuck(let why):
      if let substitution {
        self = .replaceable(substitution)
      } else {
        self = installed?.architecture == .x86_64 ? .rosettaOnly : .stuck(why)
      }
    }
  }
}

/// One plugin across the library.
struct PluginUsage: Identifiable, Hashable {
  let id: String
  let name: String
  let format: DeviceFormat
  /// Sets using it, in library order.
  var sets: [URL]
  var instances: Int
  /// The worst any of its instances fares.
  var verdict: PluginVerdict
  /// Its build in the format the sets use; `nil` when it isn't installed.
  var installed: InstalledPlugin?

  var setCount: Int { sets.count }
  /// Not installed sorts last.
  var architectureRank: Int { installed?.architecture.rawValue ?? 3 }
  var formatName: String { format.badge ?? "" }
  var verdictRank: Int { verdict.rank }
}

enum PluginIndex {
  /// Every plugin used by `scans`, without opt-in replacements applied (those are
  /// offered, not assumed).
  static func build(sets: [(URL, LiveSetScan)], inventory: PluginInventory) -> [PluginUsage] {
    var raw = inventory
    raw.substitutions = []
    var byKey: [String: PluginUsage] = [:]
    var order: [String] = []

    func add(name: String, format: DeviceFormat, set: URL, load: PluginLoad, substitution: Substitution?,
             installed: InstalledPlugin?) {
      let key = format.rawValue + ":" + name.lowercased().filter { $0.isLetter || $0.isNumber }
      let verdict = PluginVerdict(load: load, substitution: substitution, installed: installed)
      if var usage = byKey[key] {
        usage.instances += 1
        if usage.sets.last != set { usage.sets.append(set) }
        if verdict.rank < usage.verdict.rank { usage.verdict = verdict }
        usage.installed = usage.installed ?? installed
        byKey[key] = usage
      } else {
        byKey[key] = PluginUsage(id: key, name: name, format: format, sets: [set], instances: 1, verdict: verdict,
                                 installed: installed)
        order.append(key)
      }
    }

    func installed(_ s: Substitution?, _ format: DeviceFormat) -> Substitution? {
      guard let s, s.target(for: format, vst3: inventory.vst3, audioUnits: inventory.audioUnits) != nil else {
        return nil
      }
      return s
    }

    for (url, scan) in sets {
      for p in scan.vst2 {
        add(name: p.name, format: .vst, set: url, load: raw.load(p),
            substitution: installed(Substitution.allCases.first { $0.matches(p) }, .vst), installed: raw.installed(p))
      }
      for p in scan.vst3 {
        add(name: p.name, format: .vst3, set: url, load: raw.load(p),
            substitution: installed(Substitution.allCases.first { $0.matches(p) }, .vst3), installed: raw.installed(p))
      }
      for p in scan.au {
        add(name: p.name, format: .au, set: url, load: raw.load(p),
            substitution: installed(Substitution.allCases.first { $0.matches(p) }, .au), installed: raw.installed(p))
      }
    }
    return order.compactMap { byKey[$0] }
  }
}
