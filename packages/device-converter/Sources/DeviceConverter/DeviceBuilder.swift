import Foundation

/// Builds a replacement `<AuPluginDevice>` element for a structural swap.
///
/// Strategy: keep the source device's Ableton "envelope" (On, name, macros,
/// LOM ids, position…) verbatim and swap only the plugin-specific parts —
/// `PluginDesc` (identity) and `ParameterList` (old plugin's params). The AU
/// loads at default settings; parameter-bridging is a later phase.
///
/// NOTE: the exact AU block layout Ableton expects is still being validated
/// against Live 11 — this is a best-effort structure and the likely thing to
/// tweak as we test real conversions.
enum DeviceBuilder {
  static func makeAUDevice(from source: Device, target: AudioUnitInfo) -> XMLElement {
    let src = source.element
    let auDev = elem("AuPluginDevice", attrs: src.attribute(forName: "Id")?.stringValue.map { ["Id": $0] } ?? [:])

    // Copy the Ableton envelope verbatim, but swap the two plugin-specific
    // children *in place* (order matters to Live): the identity `PluginDesc`
    // becomes an AU descriptor, and the old plugin's `ParameterList` becomes
    // empty (Live repopulates it from the AU on load).
    for child in src.childElements {
      switch child.name {
      case "PluginDesc":
        auDev.addChild(makePluginDesc(target))
      case "ParameterList":
        auDev.addChild(XMLElement(name: "ParameterList"))
      default:
        if let copy = child.copy() as? XMLElement { auDev.addChild(copy) }
      }
    }
    return auDev
  }

  /// Rewrite a VST2 `<PluginDevice>` as the same plugin's VST3, carrying the
  /// plugin state and re-pointing configured parameter slots (and so their
  /// automation / macro mappings) at the VST3 parameter ids.
  ///
  /// Layout mirrors a VST3 `<PluginDevice>` saved by Live 10/11.
  static func makeVst3Device(from source: Device, conversion c: Vst3Conversion) -> XMLElement {
    if source.format == .au { return makeVst3Device(fromAU: source, conversion: c) }
    guard let dev = source.element.copy() as? XMLElement,
          let desc = dev.firstChild("PluginDesc"),
          let vst2 = desc.firstChild("VstPluginInfo"),
          let preset = vst2.firstChild("Preset")?.firstChild("VstPreset")
    else { return source.element }

    let deviceType = source.category == .instrument ? "1" : "2"
    let uid = { elem("Uid", children: c.target.uidFields.enumerated().map { val("Fields.\($0)", String($1)) }) }
    // Reuse the indentation Live gave the VST2 buffer for the new hex blobs.
    let blobIndent = preset.firstChild("Buffer")?.stringValue
      .flatMap { $0.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
      .map { String($0.prefix { $0 == "\t" }) } ?? ""

    // Vst3Preset: the shared Ableton preset fields verbatim (everything before
    // VST2's `Type`), then the VST3 identity + state.
    let v3Preset = elem("Vst3Preset", attrs: preset.attribute(forName: "Id")?.stringValue.map { ["Id": $0] } ?? [:])
    for child in preset.childElements {
      if child.name == "Type" { break }
      if let copy = child.copy() as? XMLElement { v3Preset.addChild(copy) }
    }
    v3Preset.addChild(uid())
    v3Preset.addChild(val("DeviceType", deviceType))
    v3Preset.addChild(blob("ProcessorState", c.processorState, indent: blobIndent))
    v3Preset.addChild(blob("ControllerState", c.controllerState, indent: blobIndent))
    v3Preset.addChild(val("Name", preset.childValue("Name") ?? ""))
    v3Preset.addChild((preset.firstChild("PresetRef")?.copy() as? XMLElement) ?? elem("PresetRef"))

    let info = elem("Vst3PluginInfo", attrs: ["Id": vst2.attribute(forName: "Id")?.stringValue ?? "0"])
    info.addChild(val("WinPosX", vst2.childValue("WinPosX") ?? "0"))
    info.addChild(val("WinPosY", vst2.childValue("WinPosY") ?? "0"))
    info.addChild(elem("Preset", children: [v3Preset]))
    info.addChild(val("Name", c.target.name))
    info.addChild(uid())
    info.addChild(val("DeviceType", deviceType))
    desc.replaceChild(at: vst2.index, with: info)

    remapSlots(dev, c)

    // Browser provenance: `device:vst:instr:1483109208?n=Serum` →
    // `device:vst3:instr:56535458-5866-7358-7365-72756d000000`.
    if let branch = dev.firstChild("SourceContext")?.firstChild("Value")?
      .firstChild("BranchSourceContext")?.firstChild("BranchDeviceId"),
      let v = branch.valueAttr, v.hasPrefix("device:vst:") {
      let role = source.category == .instrument ? "instr" : "audiofx"
      branch.attribute(forName: "Value")?.stringValue =
        "device:vst3:\(role):\(Vst3Uid.uuidString(c.target.cid))"
    }
    return dev
  }

  /// Rewrite an Audio Unit built around a VST2 (`<AuPluginDevice>`) as that
  /// plugin's VST3. Live wraps both in the same device envelope, so only the tag,
  /// `PluginDesc` and the parameter slots change. References to the AU's
  /// `.aupreset` files are cleared: they mean nothing to the VST3.
  private static func makeVst3Device(fromAU source: Device, conversion c: Vst3Conversion) -> XMLElement {
    guard let dev = source.element.copy() as? XMLElement,
          let desc = dev.firstChild("PluginDesc"),
          let au = desc.firstChild("AuPluginInfo"),
          let preset = au.firstChild("Preset")?.firstChild("AuPreset")
    else { return source.element }
    dev.name = "PluginDevice"

    let deviceType = source.category == .instrument ? "1" : "2"
    let uid = { elem("Uid", children: c.target.uidFields.enumerated().map { val("Fields.\($0)", String($1)) }) }
    let blobIndent = preset.firstChild("Buffer").flatMap(hexIndent) ?? ""

    // The fields every plugin preset shares come first, up to the AU's own.
    let v3Preset = elem("Vst3Preset", attrs: preset.attribute(forName: "Id")?.stringValue.map { ["Id": $0] } ?? [:])
    for child in preset.childElements {
      if ["Buffer", "PresetRef", "Name", "Manufacturer", "SubType", "Type"].contains(child.name ?? "") { break }
      if let copy = child.copy() as? XMLElement { v3Preset.addChild(copy) }
    }
    v3Preset.addChild(uid())
    v3Preset.addChild(val("DeviceType", deviceType))
    v3Preset.addChild(blob("ProcessorState", c.processorState, indent: blobIndent))
    v3Preset.addChild(blob("ControllerState", c.controllerState, indent: blobIndent))
    v3Preset.addChild(val("Name", preset.childValue("Name") ?? ""))
    v3Preset.addChild(elem("PresetRef"))

    // Live 11 keeps the bus layout (`NumAudioInputs`…) ahead of `Preset` in both.
    let info = elem("Vst3PluginInfo", attrs: ["Id": au.attribute(forName: "Id")?.stringValue ?? "0"])
    for child in au.childElements {
      guard ["WinPosX", "WinPosY", "NumAudioInputs", "NumAudioOutputs", "IsPlaceholderDevice"]
        .contains(child.name ?? "") else { continue }
      if let copy = child.copy() as? XMLElement { info.addChild(copy) }
    }
    info.addChild(elem("Preset", children: [v3Preset]))
    info.addChild(val("Name", c.target.name))
    info.addChild(uid())
    info.addChild(val("DeviceType", deviceType))
    desc.replaceChild(at: au.index, with: info)

    remapSlots(dev, c)
    for name in ["LastPresetRef", "SourceContext"] {
      dev.firstChild(name)?.setChildren([elem("Value")])
    }
    return dev
  }

  /// Configured parameter slots: VST2 index → VST3 ParamID. A slot with no VST3
  /// counterpart is unbound rather than left pointing at a wrong param.
  private static func remapSlots(_ device: XMLElement, _ c: Vst3Conversion) {
    for slot in Vst3Migration.configuredSlots(device) {
      let newId = c.parameterMap[slot.index].map { String(Int32(bitPattern: $0)) } ?? "-1"
      slot.element.firstChild("ParameterId")?.attribute(forName: "Value")?.stringValue = newId
    }
  }

  /// Replaces a hex blob's contents (`ProcessorState`, AU `Buffer`), indented as
  /// Live indents them: like the blob's current lines, or else a sibling blob's.
  static func replaceBlob(_ element: XMLElement?, with data: Data) {
    guard let element else { return }
    let siblings = (element.parent as? XMLElement)?.childElements ?? []
    let indent = ([element] + siblings).lazy.compactMap(hexIndent).first ?? ""
    let filled = blob(element.name ?? "", data, indent: indent)
    element.setChildren(nil)
    if let text = filled.stringValue, !text.isEmpty { element.stringValue = text }
  }

  private static func hexIndent(_ element: XMLElement) -> String? {
    element.stringValue?.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { String($0.prefix { $0 == "\t" }) }
  }

  /// A hex blob element formatted as Live writes it.
  private static func blob(_ name: String, _ data: Data, indent: String) -> XMLElement {
    let e = XMLElement(name: name)
    guard !data.isEmpty else { return e }
    let close = String(indent.dropLast())
    e.stringValue = "\n" + Hex.encodeLines(data).map { indent + $0 }.joined(separator: "\n") + "\n" + close
    return e
  }

  private static func makePluginDesc(_ au: AudioUnitInfo) -> XMLElement {
    let typeVal = signedString(au.typeCode)
    let subVal = signedString(au.subTypeCode)
    let mfrVal = signedString(au.manufacturerCode)

    let info = elem("AuPluginInfo", attrs: ["Id": "0"], children: [
      val("WinPosX", "0"), val("WinPosY", "0"),
      val("ComponentType", typeVal),
      val("ComponentSubType", subVal),
      val("ComponentManufacturer", mfrVal),
      val("Name", au.name),
      val("Manufacturer", au.manufacturer),
      val("ParameterCount", "0"),
      elem("Preset", children: [
        // AuPreset is a list member, so Live requires an Id. These plugin-local
        // ids aren't globally unique (real files reuse small values), so a
        // fixed value is safe.
        elem("AuPreset", attrs: ["Id": "0"], children: [
          val("OverwriteProtectionNumber", "2561"),
          elem("ParameterSettings"),
          val("IsOn", "true"),
          val("PowerMacroControlIndex", "-1"),
          elem("PowerMacroMappingRange", children: [
            val("Min", "64"), val("Max", "127"),
          ]),
          val("IsFolded", "false"),
          // No stored state → the AU loads its own defaults. (Omitting Buffer.)
          val("StoredAllParameters", "false"),
          val("DeviceLomId", "0"),
          val("DeviceViewLomId", "0"),
          val("IsOnLomId", "0"),
          val("ParametersListWrapperLomId", "0"),
          elem("PresetRef"),
          val("Name", ""),
          val("Manufacturer", mfrVal),
          val("SubType", subVal),
          val("Type", typeVal),
        ]),
      ]),
      val("IsUnusable", "false"),
    ])

    return elem("PluginDesc", children: [info])
  }

  // MARK: - XML element helpers

  /// `<Name Value="…" />`
  private static func val(_ name: String, _ value: String) -> XMLElement {
    elem(name, attrs: ["Value": value])
  }

  /// Built from text so attributes come out double-quoted, as Live writes them.
  private static func elem(
    _ name: String, attrs: [String: String] = [:], children: [XMLElement] = []
  ) -> XMLElement {
    let attributes = attrs.sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value.xmlEscaped)\"" }.joined()
    // Element names and escaped values always parse.
    let e = try! XMLElement.parsed("<\(name)\(attributes) />")
    for c in children { e.addChild(c) }
    return e
  }

  /// Ableton writes component codes as signed 32-bit ints.
  private static func signedString(_ code: OSType) -> String {
    String(Int32(bitPattern: code))
  }
}
