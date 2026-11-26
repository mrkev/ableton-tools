import Foundation

/// A native plugin build that a substitution puts in place of a device.
enum PluginTarget: Equatable, Codable {
  case vst3(Vst3PluginInfo)
  case au(AudioUnitInfo)

  var format: DeviceFormat {
    switch self {
    case .vst3: return .vst3
    case .au: return .au
    }
  }

  var badge: String { format.badge ?? "" }
}

/// An opt-in swap of an Intel-only plugin for a different one that does the same
/// job. Opt-in, because the replacement doesn't sound exactly the same.
enum Substitution: String, CaseIterable, Codable, Hashable, Identifiable {
  case orbitToMicro = "orbit"
  case proCToProC2 = "pro-c"

  var id: String { rawValue }

  var sourceName: String {
    switch self {
    case .orbitToMicro: return "AMBEO Orbit"
    case .proCToProC2: return "FabFilter Pro-C"
    }
  }

  var targetName: String {
    switch self {
    case .orbitToMicro: return OrbitToMicro.microName
    case .proCToProC2: return ProCToProC2.targetName
    }
  }

  var title: String { "\(sourceName) → \(targetName)" }

  /// Where the opt-in is remembered.
  var defaultsKey: String {
    switch self {
    case .orbitToMicro: return OrbitToMicro.defaultsKey
    case .proCToProC2: return ProCToProC2.defaultsKey
    }
  }

  /// Turns it on for `--batch` and `--vst3`.
  var cliFlag: String { "--substitute-\(rawValue)" }

  static func optedIn(arguments: [String]) -> Set<Substitution> {
    Set(allCases.filter { arguments.contains($0.cliFlag) })
  }

  /// How a replaced device sounds, for its slot in the device list.
  var outcome: String {
    switch self {
    case .orbitToMicro: return "sounds different · level matched"
    case .proCToProC2: return "settings translated · sounds close"
    }
  }

  /// What the library says about it, after "<source> is in N sets (M devices).".
  var explanation: String {
    switch self {
    case .orbitToMicro:
      return "It's discontinued and Intel only. dearVR MICRO is its successor, and the settings carry over, "
        + "but it doesn't sound the same: placement and tone shift, most at diagonal positions. Each MICRO "
        + "uses its AMBEO Orbit HRTF at Focus 100, followed by a Utility that matches Orbit's loudness for "
        + "that device."
    case .proCToProC2:
      return "It's Intel only. Pro-C 2 has the same Clean, Classic and Opto styles. Each device's settings are "
        + "translated, with attack, release, knee, side-chain filters and auto gain calibrated against renders "
        + "of both, so most devices sound very close. Pro-C 2 has no mid/side processing, so devices using it "
        + "sound different, and attacks over 250 ms are shortened to 250 ms."
    }
  }

  /// AU → AU swaps work in sets from any Live version; a VST3 needs Live 10.
  func worksBefore10(_ target: PluginTarget) -> Bool { target.format == .au && self == .proCToProC2 }

  // MARK: Identity

  func matches(_ p: LiveSetScan.Vst2Plugin) -> Bool {
    self == .orbitToMicro && OrbitToMicro.isOrbit(p)
  }

  func matches(_ p: LiveSetScan.Vst3Plugin) -> Bool {
    self == .orbitToMicro && OrbitToMicro.isOrbit(p)
  }

  func matches(_ p: LiveSetScan.AuPlugin) -> Bool {
    switch self {
    case .orbitToMicro: return OrbitToMicro.isOrbit(p)
    case .proCToProC2: return ProCToProC2.isProC(p)
    }
  }

  func matches(_ device: Device) -> Bool {
    switch self {
    case .orbitToMicro: return OrbitToMicro.isOrbit(device)
    case .proCToProC2: return ProCToProC2.isProC(device)
    }
  }

  static func matching(_ device: Device) -> Substitution? { allCases.first { $0.matches(device) } }

  /// The installed replacement for a device of `format`, or `nil`.
  func target(for format: DeviceFormat, vst3: [Vst3PluginInfo], audioUnits: [AudioUnitInfo]) -> PluginTarget? {
    switch self {
    case .orbitToMicro: return OrbitToMicro.target(for: format, vst3: vst3, audioUnits: audioUnits)
    case .proCToProC2: return ProCToProC2.target(for: format, audioUnits: audioUnits)
    }
  }

  /// Whether the replacement is installed in any format.
  func isInstalled(vst3: [Vst3PluginInfo], audioUnits: [AudioUnitInfo]) -> Bool {
    [DeviceFormat.vst, .vst3, .au].contains { target(for: $0, vst3: vst3, audioUnits: audioUnits) != nil }
  }

  /// Builds the replacement. Hosts the new plugin, so call it on the main thread.
  /// Nothing in `document` changes except its id counter, until `apply`.
  @MainActor
  func convert(
    _ device: Device, target: PluginTarget, document: AlsDocument, automatedTargets: Set<String>
  ) async throws -> SubstitutionResult {
    switch self {
    case .orbitToMicro:
      return try await OrbitToMicro.convert(
        device, target: target, document: document, automatedTargets: automatedTargets)
    case .proCToProC2:
      return try await ProCToProC2.convert(device, target: target, automatedTargets: automatedTargets)
    }
  }
}

/// A substitution's replacement for one device.
struct SubstitutionResult {
  let replacement: XMLElement
  /// Goes right after the replacement (MICRO's level-matching Utility).
  let follower: XMLElement?
  /// A short account for reports, e.g. "Utility +4.6 dB".
  let detail: String
  var notes: [String]

  /// Swaps the device for its replacement, and adds the follower after it.
  func apply(replacing device: Device) {
    let parent = device.parent
    let index = device.element.index
    parent.replaceChild(at: index, with: replacement)
    if let follower {
      let nextId = (parent.childElements.compactMap { $0.attribute(forName: "Id")?.stringValue.flatMap(Int.init) }
        .max() ?? -1) + 1
      follower.attribute(forName: "Id")?.stringValue = String(nextId)
      parent.insertChild(follower, at: index + 1)
    }
  }
}

/// Re-pointing a device's configured parameter slots (what automation and macros
/// target) at the replacement's parameters.
enum ParameterSlots {
  /// What one slot becomes, by its position in `ParameterList`. An id of -1
  /// unbinds it.
  struct Change {
    let position: Int
    let id: Int32
    let name: String
    /// A new `Manual` value, when the replacement's scale differs.
    let manual: Double?
  }

  static func apply(_ changes: [Change], to device: XMLElement) {
    guard let list = device.firstChild("ParameterList")?.childElements else { return }
    for c in changes where c.position < list.count {
      let element = list[c.position]
      element.firstChild("ParameterId")?.attribute(forName: "Value")?.stringValue = String(c.id)
      if c.id >= 0 { element.firstChild("ParameterName")?.attribute(forName: "Value")?.stringValue = c.name }
      if let manual = c.manual {
        element.firstChild("ParameterValue")?.firstChild("Manual")?.attribute(forName: "Value")?.stringValue =
          String(manual)
      }
    }
  }
}

/// Rewrites an Audio Unit device as a different Audio Unit, in place: the same
/// envelope, with the new identity, state and slots.
enum AuRetarget {
  enum Failure: Error { case unexpectedLayout }

  static func build(
    from device: Device, to target: AudioUnitInfo, state: [String: Any], parameterCount: Int,
    slots: [ParameterSlots.Change], renameReferences: (XMLElement, String) -> Void
  ) throws -> XMLElement {
    guard let copy = device.element.copy() as? XMLElement,
          let info = copy.firstChild("PluginDesc")?.firstChild("AuPluginInfo"),
          let preset = info.firstChild("Preset")?.firstChild("AuPreset"),
          let buffer = preset.firstChild("Buffer")
    else { throw Failure.unexpectedLayout }
    let type = String(Int32(bitPattern: target.typeCode))
    let subType = String(Int32(bitPattern: target.subTypeCode))
    let manufacturer = String(Int32(bitPattern: target.manufacturerCode))
    func set(_ e: XMLElement, _ name: String, _ value: String) {
      e.firstChild(name)?.attribute(forName: "Value")?.stringValue = value
    }
    set(info, "ComponentType", type)
    set(info, "ComponentSubType", subType)
    set(info, "ComponentManufacturer", manufacturer)
    set(info, "Name", target.name)
    set(info, "Manufacturer", target.manufacturer)
    set(info, "ParameterCount", String(parameterCount))
    set(preset, "Type", type)
    set(preset, "SubType", subType)
    set(preset, "Manufacturer", manufacturer)
    // Live stores AU state as an XML property list.
    let plist = try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
    DeviceBuilder.replaceBlob(buffer, with: plist)
    ParameterSlots.apply(slots, to: copy)
    renameReferences(copy, "device:au:audiofx:\(manufacturer):\(subType):\(type)")
    return copy
  }

  /// The AU state Live saved for a device, as a property list.
  static func state(of device: Device) -> [String: Any]? {
    guard let hex = device.element.firstChild("PluginDesc")?.firstChild("AuPluginInfo")?.firstChild("Preset")?
      .firstChild("AuPreset")?.firstChild("Buffer")?.stringValue,
      let data = Hex.decode(hex), !data.isEmpty
    else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
  }
}
