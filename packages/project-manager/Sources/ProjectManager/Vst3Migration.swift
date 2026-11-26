import Foundation

/// Everything needed to rewrite one VST2 device as its VST3 counterpart.
struct Vst3Conversion {
  let target: Vst3PluginInfo
  /// `ProcessorState` — the component state as the VST3 itself re-emits it
  /// after loading the VST2 chunk.
  let processorState: Data
  /// `ControllerState` (often empty).
  let controllerState: Data
  /// VST2 parameter index → VST3 ParamID, for the device's configured
  /// parameter slots (the ones automation and macros point at).
  let parameterMap: [Int: UInt32]
  /// Human-readable lines describing `parameterMap`.
  let mapping: [String]
  /// Parameters whose value differs from a freshly-instantiated plugin — a
  /// sanity check that the state actually took.
  let changedFromDefault: Int
  let parameterCount: Int
  var warnings: [String]
}

/// Whether a VST2 device (or an AU built around a VST2) can be converted to
/// VST3, and if not, why.
enum Vst3Availability: Equatable {
  case available(Vst3PluginInfo)
  case unavailable(String)

  static let noVst3 = "no native VST3 installed"
  static let unsupportedPreset = "preset type not supported yet"
  static let notCompatible = "its VST3 can't load VST2 settings"

  /// Ignores the set's Live version: see `SetStatus.needsResave`. Chunks and
  /// parameter dumps both count; whether the VST3 can take a parameter dump is
  /// only known once it's loaded, and the conversion says so if not.
  static func resolve(_ plugin: LiveSetScan.Vst2Plugin, catalog: [Vst3PluginInfo]) -> Vst3Availability {
    guard let target = Vst3Migration.target(uniqueId: plugin.uniqueId, name: plugin.name, in: catalog) else {
      let lowered = plugin.name.lowercased()
      return .unavailable(catalog.contains { $0.name.lowercased() == lowered } ? notCompatible : noVst3)
    }
    return plugin.isChunk || plugin.isParameterDump ? .available(target) : .unavailable(unsupportedPreset)
  }

  /// An AU built around a VST2 uses the VST2's unique id as its subtype, so the
  /// VST3 that replaces the VST2 replaces it too. `nil` for any other AU.
  static func resolve(_ plugin: LiveSetScan.AuPlugin, catalog: [Vst3PluginInfo]) -> Vst3Availability? {
    Vst3Migration.target(uniqueId: plugin.subType, name: plugin.name, in: catalog).map { .available($0) }
  }

  /// For a device in an open set: `nil` unless it's a VST2 device, or an AU with
  /// a VST3 that replaces it.
  static func resolve(_ device: Device, catalog: [Vst3PluginInfo]) -> Vst3Availability? {
    switch device.format {
    case .vst:
      let type = Vst2State.presetType(device.element)
      return resolve(LiveSetScan.Vst2Plugin(
        name: device.product, uniqueId: Vst3Migration.vst2UniqueId(device),
        isChunk: type == "FBCh", isParameterDump: type == "FxBk"), catalog: catalog)
    case .au:
      return LiveSetScan.AuPlugin(device: device).flatMap { resolve($0, catalog: catalog) }
    default:
      return nil
    }
  }
}

enum Vst3MigrationError: Error, CustomStringConvertible {
  case notVst2
  case noState
  case notWrappedVst2
  case unsupportedPreset(String)
  case parametersNotAccepted
  case settingsNotCarried(String)

  var description: String {
    switch self {
    case .notVst2: return "not a VST2 device"
    case .noState: return "no saved VST2 state found"
    case .notWrappedVst2: return "this Audio Unit doesn't keep VST2 settings"
    case .unsupportedPreset(let t): return "'\(t)' presets can't be carried over yet"
    case .parametersNotAccepted:
      return "its VST3 doesn't store plain parameter values, so these settings can't be carried over yet"
    case .settingsNotCarried(let what): return "settings didn't carry over: \(what)"
    }
  }
}

enum Vst3Migration {
  /// The installed VST3 that declares it replaces this VST2 device, through the
  /// VST2-compatible class id. A VST3 that merely shares the name doesn't qualify:
  /// it can report success loading a VST2 chunk while ignoring it (Melda's do).
  static func target(for device: Device, in catalog: [Vst3PluginInfo]) -> Vst3PluginInfo? {
    if case .available(let target)? = Vst3Availability.resolve(device, catalog: catalog) { return target }
    return nil
  }

  static func target(uniqueId: Int32?, name: String, in catalog: [Vst3PluginInfo]) -> Vst3PluginInfo? {
    guard let uniqueId else { return nil }
    let want = Vst3Uid.vst2Compatible(uniqueId: uniqueId, name: name)
    return catalog.first { $0.cid == want }
  }

  static func vst2UniqueId(_ device: Device) -> Int32? {
    device.element.firstChild("PluginDesc")?.firstChild("VstPluginInfo")?
      .childValue("UniqueId").flatMap(Int32.init)
  }

  /// Load the VST2 state into the target VST3 and work out the parameter
  /// mapping. `automatedTargets` holds the `AutomationTarget` ids that have
  /// envelopes in the set (their `Manual` value isn't the patch value, so they
  /// are skipped by the value cross-check).
  static func prepare(
    _ device: Device, target: Vst3PluginInfo, automatedTargets: Set<String> = []
  ) throws -> Vst3Conversion {
    let legacy = try LegacyPreset(device: device)
    let fresh = try defaults(of: target)
    let defaults = fresh.parameters
    let state: Data
    switch legacy {
    case .chunk(let vst2):
      guard let wrapped = vst2.vst3CompatibleState() else { throw Vst3MigrationError.unsupportedPreset(vst2.type) }
      state = wrapped
    case .parameters(let values):
      state = try parameterState(values, defaults: fresh)
    }

    let plugin = try Vst3Instance(target)
    try plugin.setState(state)
    let params = plugin.parameters
    var warnings: [String] = []

    // A parameter dump is checked value by value: every one must have arrived.
    if case .parameters(let values) = legacy {
      guard params.count >= values.count else { throw Vst3MigrationError.parametersNotAccepted }
      for (i, value) in values.enumerated() where abs(params[i].normalized - Double(value)) > 1e-4 {
        throw Vst3MigrationError.settingsNotCarried(
          String(format: "'%@' loads as %.4f but was %.4f", params[i].title, params[i].normalized, value))
      }
    }

    let defaultById = Dictionary(defaults.map { ($0.id, $0.normalized) }, uniquingKeysWith: { a, _ in a })
    let changed = params.filter { p in
      defaultById[p.id].map { abs($0 - p.normalized) > 1e-6 } ?? false
    }.count
    // Only a chunk needs this guess; a parameter dump was checked value by value.
    if case .chunk = legacy, changed == 0, !params.isEmpty {
      warnings.append("no parameter moved off its default after loading — the patch may be the plugin's init patch, or the state wasn't accepted")
    }

    // Map configured slots: VST2 index → VST3 id, by name.
    var map: [Int: UInt32] = [:]
    var mapping: [String] = []
    let byTitle = Dictionary(grouping: params, by: { titleKey($0.title) })
    // Plugins whose VST3 ids are the VST2 indices (JUCE legacy ids, Steinberg's
    // wrapper) can be mapped by index even when a title changed between
    // versions (Serum: "LFO1Rate" → "LFO1 Rate") or is patch-dependent.
    let vst2Count: Int
    if case .parameters(let values) = legacy {
      vst2Count = values.count
    } else {
      vst2Count = device.element.firstChild("PluginDesc")?.firstChild("VstPluginInfo")?
        .childValue("NumberOfParameters").flatMap(Int.init) ?? 0
    }
    let indexIds = vst2Count > 0 && params.count >= vst2Count
      && params.prefix(vst2Count).enumerated().allSatisfy { Int($0.element.id) == $0.offset }
    for slot in configuredSlots(device.element) {
      let match: Vst3Instance.Parameter
      let key = titleKey(slot.name)
      if let p = params.first(where: { Int($0.id) == slot.index && titleKey($0.title) == key }) {
        match = p
      } else if let hits = byTitle[key], hits.count == 1 {
        match = hits[0]
      } else if indexIds, slot.index < vst2Count {
        match = params[slot.index]
      } else {
        warnings.append("parameter \(slot.index) '\(slot.name)' has no VST3 match; it will be unbound")
        continue
      }
      map[slot.index] = match.id
      let automated = slot.hasInlineAutomation
        || (slot.automationTarget.map(automatedTargets.contains) ?? false)
      mapping.append("#\(slot.index) '\(slot.name)' → id \(match.id) '\(match.title)'"
        + (automated ? " (automated)" : ""))
      // Cross-check the loaded value against what Live last saw. A difference
      // means the plugin didn't really take the state, so keep the VST2 device.
      if !automated, let live = slot.value, abs(match.normalized - live) > 0.01 {
        throw Vst3MigrationError.settingsNotCarried(
          String(format: "'%@' loads as %.3f but Live had %.3f", slot.name, match.normalized, live))
      }
    }

    return Vst3Conversion(
      target: target,
      processorState: plugin.componentState() ?? state,
      controllerState: plugin.controllerState() ?? Data(),
      parameterMap: map,
      mapping: mapping,
      changedFromDefault: changed,
      parameterCount: params.count,
      warnings: warnings)
  }

  /// A freshly instantiated VST3: its parameters and the state it saves.
  struct Defaults {
    let parameters: [Vst3Instance.Parameter]
    let state: Data?
  }

  private static var defaultsCache: [[UInt8]: Defaults] = [:]

  private static func defaults(of target: Vst3PluginInfo) throws -> Defaults {
    if let cached = defaultsCache[target.cid] { return cached }
    let plugin = try Vst3Instance(target)
    let fresh = Defaults(parameters: plugin.parameters, state: plugin.componentState())
    defaultsCache[target.cid] = fresh
    return fresh
  }

  /// Some VST3s (OTT) save nothing but their parameters' values, as
  /// little-endian floats in parameter order. Recognized by a fresh instance's
  /// state being exactly that; then a VST2 parameter dump becomes a state by
  /// putting its values first, keeping the defaults of any extra parameters
  /// (OTT's VST3 adds Bypass).
  static func parameterState(_ values: [Float], defaults: Defaults) throws -> Data {
    guard let own = defaults.state, own.count % 4 == 0 else { throw Vst3MigrationError.parametersNotAccepted }
    var floats = Data.floats(own, bigEndian: false)
    guard floats.count >= values.count, floats.count <= defaults.parameters.count,
          zip(floats, defaults.parameters).allSatisfy({ abs(Double($0) - $1.normalized) < 1e-6 })
    else { throw Vst3MigrationError.parametersNotAccepted }
    floats.replaceSubrange(0..<values.count, with: values)
    return Data(littleEndianFloats: floats)
  }

  struct ConfiguredSlot {
    let element: XMLElement
    let index: Int
    let name: String
    let value: Double?
    let automationTarget: String?
    /// Pre-Live-10 sets keep arrangement automation inline in the parameter.
    let hasInlineAutomation: Bool
  }

  /// Titles compared ignoring case, spaces and punctuation.
  private static func titleKey(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
  }

  /// `PluginFloatParameter`s bound to a plugin parameter (`ParameterId` ≠ -1).
  static func configuredSlots(_ device: XMLElement) -> [ConfiguredSlot] {
    guard let list = device.firstChild("ParameterList") else { return [] }
    return list.childElements.compactMap { p in
      guard let id = p.childValue("ParameterId").flatMap(Int.init), id >= 0 else { return nil }
      let value = p.firstChild("ParameterValue")
      return ConfiguredSlot(
        element: p, index: id, name: p.childValue("ParameterName") ?? "",
        value: value?.childValue("Manual").flatMap(Double.init),
        automationTarget: value?.firstChild("AutomationTarget")?.attribute(forName: "Id")?.stringValue,
        hasInlineAutomation: (value?.firstChild("ArrangerAutomation")?.firstChild("Events")?
          .childElements.count ?? 0) > 1)
    }
  }
}
