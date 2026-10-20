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
    let auDev = XMLElement(name: "AuPluginDevice")
    if let id = src.attribute(forName: "Id")?.stringValue {
      auDev.addAttribute(attr("Id", id))
    }

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

  private static func attr(_ name: String, _ value: String) -> XMLNode {
    let a = XMLNode(kind: .attribute)
    a.name = name
    a.stringValue = value
    return a
  }

  /// `<Name Value="…"/>`
  private static func val(_ name: String, _ value: String) -> XMLElement {
    let e = XMLElement(name: name)
    e.addAttribute(attr("Value", value))
    return e
  }

  private static func elem(
    _ name: String, attrs: [String: String] = [:], children: [XMLElement] = []
  ) -> XMLElement {
    let e = XMLElement(name: name)
    for (k, v) in attrs { e.addAttribute(attr(k, v)) }
    for c in children { e.addChild(c) }
    return e
  }

  /// Ableton writes component codes as signed 32-bit ints.
  private static func signedString(_ code: OSType) -> String {
    String(Int32(bitPattern: code))
  }
}
