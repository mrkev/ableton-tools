import Foundation

/// What a plugin needs to work in a native Live, before any per-set choice.
enum PluginVerdict: Hashable {
  case native
  /// A VST3 of it replaces it, keeping its settings.
  case converts(to: String)
  /// A different plugin can stand in for it (`Substitution`).
  case replaceable(Substitution)
  case stuck(String)

  /// Most in need of attention first.
  var rank: Int {
    switch self {
    case .stuck: return 0
    case .replaceable: return 1
    case .converts: return 2
    case .native: return 3
    }
  }

  var title: String {
    switch self {
    case .native: return "Works natively"
    case .converts(let target): return "Converts to \(target) VST3"
    case .replaceable(let s): return "Can be replaced with \(s.targetName)"
    case .stuck: return "Won't load"
    }
  }

  var detail: String? {
    switch self {
    case .stuck(let why): return why
    case .replaceable(let s): return s.outcome
    case .converts: return "keeps its settings"
    case .native: return nil
    }
  }

  init(load: PluginLoad, substitution: Substitution?) {
    switch load {
    case .native: self = .native
    case .needsConversion(let target): self = .converts(to: target.name)
    case .substitute(let s, _): self = .replaceable(s)
    case .stuck(let why): self = substitution.map { .replaceable($0) } ?? .stuck(why)
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

  var setCount: Int { sets.count }
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

    func add(name: String, format: DeviceFormat, set: URL, load: PluginLoad, substitution: Substitution?) {
      let key = format.rawValue + ":" + name.lowercased().filter { $0.isLetter || $0.isNumber }
      let verdict = PluginVerdict(load: load, substitution: substitution)
      if var usage = byKey[key] {
        usage.instances += 1
        if usage.sets.last != set { usage.sets.append(set) }
        if verdict.rank < usage.verdict.rank { usage.verdict = verdict }
        byKey[key] = usage
      } else {
        byKey[key] = PluginUsage(id: key, name: name, format: format, sets: [set], instances: 1, verdict: verdict)
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
            substitution: installed(Substitution.allCases.first { $0.matches(p) }, .vst))
      }
      for p in scan.vst3 {
        add(name: p.name, format: .vst3, set: url, load: raw.load(p),
            substitution: installed(Substitution.allCases.first { $0.matches(p) }, .vst3))
      }
      for p in scan.au {
        add(name: p.name, format: .au, set: url, load: raw.load(p),
            substitution: installed(Substitution.allCases.first { $0.matches(p) }, .au))
      }
    }
    return order.compactMap { byKey[$0] }
  }
}
