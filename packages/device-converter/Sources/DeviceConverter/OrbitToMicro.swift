import AVFoundation
import Foundation

/// Replaces Sennheiser AMBEO Orbit (discontinued, Intel only) with dearVR MICRO,
/// its successor. Opt-in, because it changes the sound.
///
/// MICRO has every Orbit control under the same parameter ids, except that
/// Clarity became Focus and an HRTF choice was added. Its saved state is the same
/// JUCE XML, so the settings carry over directly. It still doesn't sound like
/// Orbit, even with its "AMBEO Orbit" HRTF: offline renders of both (checked
/// against bounces from Live) differ in placement and tone, most at diagonal
/// positions, and no Focus value matches Clarity. Focus 100 comes closest.
///
/// MICRO is also 2.5 to 7 dB quieter depending on the settings, and has no output
/// gain. So each MICRO is followed by a Utility whose gain restores the loudness
/// Orbit had at that device's settings (`OrbitGainTable`).
enum OrbitToMicro {
  static let microName = "dearVR MICRO"
  /// A short description of the substitution for the UI.
  static let title = "AMBEO Orbit → dearVR MICRO"
  /// The Utility's name in Live.
  static let utilityName = "MICRO level match"
  /// Where the opt-in is remembered.
  static let defaultsKey = "substituteAmbeoOrbit"

  // MARK: Identity

  static let orbitVst2Id: Int32 = 1_399_144_783  // 'SeAO'
  static let orbitAuSubType: Int32 = 1_399_144_783  // 'SeAO'
  static let orbitAuManufacturer: Int32 = 1_399_156_334  // 'Senn'
  static let microAuSubType: Int32 = 1_684_368_745  // 'demi'
  static let microAuManufacturer: Int32 = 1_147_494_770  // 'Dear'
  /// Orbit's VST3 uses the VST2-compatible class id.
  static let orbitVst3Uid = Vst3Uid.fields(Vst3Uid.vst2Compatible(uniqueId: orbitVst2Id, name: "AMBEO Orbit"))

  static func isOrbit(_ p: LiveSetScan.Vst2Plugin) -> Bool { p.uniqueId == orbitVst2Id }
  static func isOrbit(_ p: LiveSetScan.Vst3Plugin) -> Bool { p.uid == orbitVst3Uid }
  static func isOrbit(_ p: LiveSetScan.AuPlugin) -> Bool {
    p.subType == orbitAuSubType && p.manufacturer == orbitAuManufacturer
  }

  static func isOrbit(_ device: Device) -> Bool {
    switch device.format {
    case .vst: return Vst3Migration.vst2UniqueId(device) == orbitVst2Id
    case .vst3: return device.vst3Uid == orbitVst3Uid
    case .au:
      let info = device.element.firstChild("PluginDesc")?.firstChild("AuPluginInfo")
      return info?.childValue("ComponentSubType").flatMap(Int32.init) == orbitAuSubType
        && info?.childValue("ComponentManufacturer").flatMap(Int32.init) == orbitAuManufacturer
    default: return false
    }
  }

  /// The MICRO build that replaces an Orbit device.
  enum Target: Equatable, Codable {
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

  /// An AU stays an AU; VST2 and VST3 become VST3 (MICRO has no VST2). `nil`
  /// when no native MICRO is installed in that format.
  static func target(
    for format: DeviceFormat, vst3: [Vst3PluginInfo], audioUnits: [AudioUnitInfo]
  ) -> Target? {
    switch format {
    case .au:
      return audioUnits.first {
        $0.isNative && Int32(bitPattern: $0.subTypeCode) == microAuSubType
          && Int32(bitPattern: $0.manufacturerCode) == microAuManufacturer
      }.map(Target.au)
    case .vst, .vst3:
      return vst3.first { $0.name == microName }.map(Target.vst3)
    default:
      return nil
    }
  }

  // MARK: Settings

  /// Orbit's parameters as its state stores them, e.g. `param_azimuth` → "-28".
  struct Settings {
    let values: [String: String]

    func number(_ id: String) -> Double? { values[id].flatMap(Double.init) }
  }

  static func settings(of device: Device) -> Settings? {
    guard let blob = stateBlob(of: device), let xml = JuceState.xml(in: blob) else { return nil }
    return Settings(values: JuceState.parameters(in: xml))
  }

  /// The bytes holding the JUCE state in each format's preset.
  private static func stateBlob(of device: Device) -> Data? {
    guard let desc = device.element.firstChild("PluginDesc") else { return nil }
    switch device.format {
    case .vst:
      return Vst2State(device: device.element)?.buffer
    case .vst3:
      return desc.firstChild("Vst3PluginInfo")?.firstChild("Preset")?.firstChild("Vst3Preset")?
        .firstChild("ProcessorState")?.stringValue.flatMap(Hex.decode)
    case .au:
      guard let hex = auPreset(desc)?.firstChild("Buffer")?.stringValue,
            let data = Hex.decode(hex),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
      else { return nil }
      return plist["jucePluginState"] as? Data
    default:
      return nil
    }
  }

  private static func auPreset(_ desc: XMLElement) -> XMLElement? {
    desc.firstChild("AuPluginInfo")?.firstChild("Preset")?.firstChild("AuPreset")
  }

  /// MICRO's parameters, in the order it writes them.
  private static let microParameters = [
    "param_azimuth", "param_elevation", "param_focus", "param_hrtf_selection", "param_reflection_enable",
    "param_reflection_level", "param_reflection_room", "param_reflection_size", "param_width",
  ]
  /// The Orbit parameters that carry over unchanged.
  private static let shared = microParameters.filter { $0 != "param_focus" && $0 != "param_hrtf_selection" }
  static let focus = "100"
  /// MICRO's HRTF choice: 0 dearVR, 1 AMBEO Orbit.
  static let ambeoHrtf = "1"

  static func microXml(from orbit: Settings) throws -> String {
    let missing = shared.filter { orbit.values[$0] == nil }
    guard missing.isEmpty else {
      throw OrbitError.incompleteState(missing.joined(separator: ", "))
    }
    var values = orbit.values.filter { shared.contains($0.key) }
    values["param_focus"] = focus
    values["param_hrtf_selection"] = ambeoHrtf
    return "<State>"
      + microParameters.map { "<PARAM id=\"\($0)\" value=\"\(values[$0]!)\"/>" }.joined()
      + "</State>"
  }

  /// Checks MICRO kept what it was given, using the state it saves itself.
  private static func verify(_ saved: Data?, against orbit: Settings) throws {
    guard let saved, let xml = JuceState.xml(in: saved) else { throw OrbitError.noStateBack }
    let micro = Settings(values: JuceState.parameters(in: xml))
    var expected = shared.map { ($0, orbit.number($0)) }
    expected += [("param_focus", Double(focus)), ("param_hrtf_selection", Double(ambeoHrtf))]
    for (id, want) in expected {
      guard let want, let got = micro.number(id), abs(got - want) <= max(1e-3, abs(want) * 1e-4) else {
        throw OrbitError.settingsNotCarried(
          "\(id) is \(micro.values[id] ?? "missing"), expected \(orbit.values[id] ?? "\(want ?? .nan)")")
      }
    }
  }

  // MARK: Conversion

  struct Conversion {
    let replacement: XMLElement
    /// Goes right after `replacement`.
    let utility: XMLElement
    let gainDb: Double
    var notes: [String]
  }

  /// Builds the MICRO device and its Utility. Hosts MICRO, so call it on the main
  /// thread. Nothing in `document` changes except its id counter, until `apply`.
  @MainActor
  static func convert(
    _ device: Device, target: Target, document: AlsDocument, automatedTargets: Set<String>
  ) async throws -> Conversion {
    guard isOrbit(device) else { throw OrbitError.notOrbit }
    guard let orbit = settings(of: device) else { throw OrbitError.noState }
    let juce = JuceState.encode(xml: try microXml(from: orbit))
    var notes: [String] = []

    let replacement: XMLElement
    let parameters: [Vst3Instance.Parameter]
    switch target {
    case .vst3(let info):
      let micro = try Vst3Instance(info)
      try micro.setState(juce)
      let processor = micro.componentState()
      try verify(processor, against: orbit)
      parameters = micro.parameters
      let slots = try slotPlan(device, parameters: parameters, automated: automatedTargets, notes: &notes)
      let built = try buildVst3(
        from: device, target: info, processor: processor!, controller: micro.controllerState() ?? Data(),
        slots: slots)
      replacement = built
    case .au(let au):
      let (state, params) = try await AuHost.load(au, fullState: [
        "type": Int(au.typeCode), "subtype": Int(au.subTypeCode), "manufacturer": Int(au.manufacturerCode),
        "version": 0, "name": "Untitled", "jucePluginState": juce,
      ])
      try verify(state["jucePluginState"] as? Data, against: orbit)
      parameters = params
      let slots = try slotPlan(device, parameters: parameters, automated: automatedTargets, notes: &notes)
      replacement = try buildAu(from: device, target: au, state: state, parameterCount: params.count, slots: slots)
    }

    let azimuth = orbit.number("param_azimuth") ?? 0
    let gain = OrbitGainTable.makeupDb(
      azimuth: azimuth, elevation: orbit.number("param_elevation") ?? 0,
      width: orbit.number("param_width") ?? 0, clarity: orbit.number("param_clarity") ?? 0,
      reflectionLevel: (orbit.number("param_reflection_enable") ?? 0) >= 0.5
        ? orbit.number("param_reflection_level") ?? 0 : nil)
    let positionAutomated = Vst3Migration.configuredSlots(device.element).contains { slot in
      ["azimuth", "elevation", "width"].contains(slot.name.lowercased())
        && (slot.hasInlineAutomation || slot.automationTarget.map(automatedTargets.contains) == true)
    }
    if positionAutomated {
      notes.append(String(
        format: "position is automated, so the %+.1f dB level match fits only its saved settings", gain))
    }
    if onIsAutomated(device, automatedTargets) {
      notes.append("its on/off is automated, but the level-match Utility's isn't")
    }
    let utility = try UtilityDevice.make(
      gainDb: gain, isOn: device.enabled, name: utilityName, document: document)
    return Conversion(replacement: replacement, utility: utility, gainDb: gain, notes: notes)
  }

  /// Swaps the device for MICRO and puts the Utility right after it.
  static func apply(_ c: Conversion, replacing device: Device) {
    let parent = device.parent
    let index = device.element.index
    let nextId = (parent.childElements.compactMap { $0.attribute(forName: "Id")?.stringValue.flatMap(Int.init) }
      .max() ?? -1) + 1
    c.utility.attribute(forName: "Id")?.stringValue = String(nextId)
    parent.replaceChild(at: index, with: c.replacement)
    parent.insertChild(c.utility, at: index + 1)
  }

  private static func onIsAutomated(_ device: Device, _ automated: Set<String>) -> Bool {
    guard let id = device.element.firstChild("On")?.firstChild("AutomationTarget")?
      .attribute(forName: "Id")?.stringValue else { return false }
    return automated.contains(id)
  }

  // MARK: Parameter slots

  /// What each configured slot becomes, by its position in `ParameterList`.
  private struct SlotChange {
    let position: Int
    let id: Int32
    let name: String
    let manual: Double?
  }

  /// Slots are matched by name. Clarity's slot becomes Focus, unless Clarity is
  /// automated: its envelope wouldn't mean the same thing for Focus.
  private static func slotPlan(
    _ device: Device, parameters: [Vst3Instance.Parameter], automated: Set<String>, notes: inout [String]
  ) throws -> [SlotChange] {
    guard let list = device.element.firstChild("ParameterList") else { return [] }
    let byTitle = Dictionary(parameters.map { (titleKey($0.title), $0) }, uniquingKeysWith: { a, _ in a })
    let slots = Vst3Migration.configuredSlots(device.element)
    var out: [SlotChange] = []
    for (position, element) in list.childElements.enumerated() {
      guard let slot = slots.first(where: { $0.element === element }) else { continue }
      let isAutomated = slot.hasInlineAutomation || slot.automationTarget.map(automated.contains) == true
      let isClarity = titleKey(slot.name) == "clarity"
      if isClarity && isAutomated {
        notes.append("Clarity is automated; that automation is dropped, since Focus works differently")
        out.append(SlotChange(position: position, id: -1, name: "", manual: nil))
        continue
      }
      guard let p = byTitle[isClarity ? "focus" : titleKey(slot.name)] else {
        notes.append("parameter '\(slot.name)' has no MICRO match; it will be unbound")
        out.append(SlotChange(position: position, id: -1, name: "", manual: nil))
        continue
      }
      // Live's value should be what the state holds; a difference means the
      // settings didn't arrive, so keep Orbit.
      if !isClarity, !isAutomated, let live = slot.value, abs(p.normalized - live) > 0.01 {
        throw OrbitError.settingsNotCarried(
          String(format: "'%@' loads as %.3f but Live had %.3f", slot.name, p.normalized, live))
      }
      out.append(SlotChange(
        position: position, id: Int32(bitPattern: p.id), name: p.title,
        manual: isClarity ? p.normalized : nil))
    }
    return out
  }

  private static func applySlots(_ slots: [SlotChange], to device: XMLElement) {
    guard let list = device.firstChild("ParameterList")?.childElements else { return }
    for s in slots where s.position < list.count {
      let element = list[s.position]
      element.firstChild("ParameterId")?.attribute(forName: "Value")?.stringValue = String(s.id)
      if s.id >= 0 { element.firstChild("ParameterName")?.attribute(forName: "Value")?.stringValue = s.name }
      if let manual = s.manual {
        element.firstChild("ParameterValue")?.firstChild("Manual")?.attribute(forName: "Value")?.stringValue =
          String(manual)
      }
    }
  }

  private static func titleKey(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
  }

  // MARK: Building devices

  private static func buildVst3(
    from device: Device, target: Vst3PluginInfo, processor: Data, controller: Data, slots: [SlotChange]
  ) throws -> XMLElement {
    let built: XMLElement
    switch device.format {
    case .vst:
      // The VST2 → VST3 rewrite, with slot ids filled in from the plan below.
      let conversion = Vst3Conversion(
        target: target, processorState: processor, controllerState: controller, parameterMap: [:],
        mapping: [], changedFromDefault: 0, parameterCount: 0, warnings: [])
      built = DeviceBuilder.makeVst3Device(from: device, conversion: conversion)
      guard built !== device.element else { throw OrbitError.unexpectedLayout }
    case .vst3:
      guard let copy = device.element.copy() as? XMLElement,
            let info = copy.firstChild("PluginDesc")?.firstChild("Vst3PluginInfo"),
            let preset = info.firstChild("Preset")?.firstChild("Vst3Preset")
      else { throw OrbitError.unexpectedLayout }
      for uid in [info.firstChild("Uid"), preset.firstChild("Uid")].compactMap({ $0 }) {
        for (i, field) in target.uidFields.enumerated() {
          uid.firstChild("Fields.\(i)")?.attribute(forName: "Value")?.stringValue = String(field)
        }
      }
      info.firstChild("Name")?.attribute(forName: "Value")?.stringValue = target.name
      DeviceBuilder.replaceBlob(preset.firstChild("ProcessorState"), with: processor)
      DeviceBuilder.replaceBlob(preset.firstChild("ControllerState"), with: controller)
      built = copy
    default:
      throw OrbitError.notOrbit
    }
    applySlots(slots, to: built)
    renameReferences(in: built, branch: "device:vst3:audiofx:\(Vst3Uid.uuidString(target.cid))")
    return built
  }

  private static func buildAu(
    from device: Device, target: AudioUnitInfo, state: [String: Any], parameterCount: Int, slots: [SlotChange]
  ) throws -> XMLElement {
    guard let copy = device.element.copy() as? XMLElement,
          let desc = copy.firstChild("PluginDesc"),
          let info = desc.firstChild("AuPluginInfo"),
          let preset = auPreset(desc)
    else { throw OrbitError.unexpectedLayout }
    let subType = String(Int32(bitPattern: target.subTypeCode))
    let manufacturer = String(Int32(bitPattern: target.manufacturerCode))
    func set(_ e: XMLElement, _ name: String, _ value: String) {
      e.firstChild(name)?.attribute(forName: "Value")?.stringValue = value
    }
    set(info, "ComponentSubType", subType)
    set(info, "ComponentManufacturer", manufacturer)
    set(info, "Name", target.name)
    set(info, "Manufacturer", target.manufacturer)
    set(info, "ParameterCount", String(parameterCount))
    set(preset, "SubType", subType)
    set(preset, "Manufacturer", manufacturer)
    // Live stores AU state as an XML property list.
    let plist = try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
    guard let buffer = preset.firstChild("Buffer") else { throw OrbitError.unexpectedLayout }
    DeviceBuilder.replaceBlob(buffer, with: plist)
    applySlots(slots, to: copy)
    let type = String(Int32(bitPattern: target.typeCode))
    renameReferences(in: copy, branch: "device:au:audiofx:\(manufacturer):\(subType):\(type)")
    return copy
  }

  /// Browser references (`BranchDeviceId`, preset paths under Ableton's AU preset
  /// cache, `query:Find#AMBEO%20Orbit`) would otherwise still name Orbit. The
  /// user's own device name and annotation are left alone.
  private static func renameReferences(in device: XMLElement, branch: String) {
    var stack = [device]
    while let e = stack.popLast() {
      switch e.name {
      case "UserName", "Annotation", "ParameterList": continue
      case "BranchDeviceId": e.attribute(forName: "Value")?.stringValue = branch; continue
      default: break
      }
      for attribute in e.attributes ?? [] where attribute.name == "Value" || attribute.name == "Dir" {
        guard let v = attribute.stringValue else { continue }
        let renamed = v == "Sennheiser" ? "Dear Reality"
          : v.replacingOccurrences(of: "Sennheiser/AMBEO Orbit", with: "Dear Reality/dearVR MICRO")
            .replacingOccurrences(of: "AMBEO%20Orbit", with: "dearVR%20MICRO")
            .replacingOccurrences(of: "AMBEO Orbit", with: microName)
        if renamed != v { attribute.stringValue = renamed }
      }
      stack += e.childElements
    }
  }
}

enum OrbitError: Error, CustomStringConvertible {
  case notOrbit
  case noState
  case incompleteState(String)
  case noStateBack
  case settingsNotCarried(String)
  case unexpectedLayout
  case auUnavailable(String)

  var description: String {
    switch self {
    case .notOrbit: return "not an AMBEO Orbit device"
    case .noState: return "no readable Orbit settings in the set"
    case .incompleteState(let ids): return "Orbit's saved settings lack \(ids)"
    case .noStateBack: return "dearVR MICRO didn't return its settings"
    case .settingsNotCarried(let what): return "settings didn't carry over: \(what)"
    case .unexpectedLayout: return "the device isn't laid out as expected"
    case .auUnavailable(let why): return "couldn't load dearVR MICRO: \(why)"
    }
  }
}

/// JUCE's binary state: `VC2!`, the XML's length (little-endian), the XML, a NUL,
/// then optional private data.
enum JuceState {
  private static let magic = Data("VC2!".utf8)

  static func xml(in data: Data) -> String? {
    guard let r = data.range(of: magic), data.distance(from: r.upperBound, to: data.endIndex) >= 4 else {
      return nil
    }
    let length = data[r.upperBound..<(r.upperBound + 4)].enumerated()
      .reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    let start = r.upperBound + 4
    guard length > 0, data.distance(from: start, to: data.endIndex) >= length else { return nil }
    return String(data: data[start..<(start + length)], encoding: .utf8)
  }

  static func encode(xml: String) -> Data {
    var out = magic
    var length = UInt32(xml.utf8.count).littleEndian
    out.append(Data(bytes: &length, count: 4))
    out.append(Data(xml.utf8))
    out.append(0)
    return out
  }

  /// `<PARAM id="…" value="…"/>` pairs.
  static func parameters(in xml: String) -> [String: String] {
    guard let re = try? NSRegularExpression(pattern: #"<PARAM id="([^"]+)" value="([^"]*)"\s*/>"#) else { return [:] }
    var out: [String: String] = [:]
    for m in re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
      guard let id = Range(m.range(at: 1), in: xml), let value = Range(m.range(at: 2), in: xml) else { continue }
      out[String(xml[id])] = String(xml[value])
    }
    return out
  }
}

/// Loads an Audio Unit in this process to let it re-save a state.
@MainActor
enum AuHost {
  static func load(
    _ au: AudioUnitInfo, fullState: [String: Any]
  ) async throws -> (state: [String: Any], parameters: [Vst3Instance.Parameter]) {
    let description = AudioComponentDescription(
      componentType: au.typeCode, componentSubType: au.subTypeCode, componentManufacturer: au.manufacturerCode,
      componentFlags: 0, componentFlagsMask: 0)
    let unit: AVAudioUnit
    do {
      unit = try await AVAudioUnit.instantiate(with: description, options: [])
    } catch {
      throw OrbitError.auUnavailable(error.localizedDescription)
    }
    unit.auAudioUnit.fullState = fullState
    // JUCE applies some of a state on the main thread.
    Vst3Instance.pumpMainRunLoop()
    guard let saved = unit.auAudioUnit.fullState else { throw OrbitError.noStateBack }
    let parameters = (unit.auAudioUnit.parameterTree?.allParameters ?? []).map {
      Vst3Instance.Parameter(id: UInt32(truncatingIfNeeded: $0.address), title: $0.displayName,
                             normalized: Double($0.value))
    }
    return (saved, parameters)
  }
}
