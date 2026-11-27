import AVFoundation
import Foundation

/// An Audio Unit installed on this Mac, with the component codes Ableton needs.
struct AudioUnitInfo: Identifiable, Hashable, Codable {
  var id = UUID()
  let name: String
  let manufacturer: String
  let typeCode: OSType
  let subTypeCode: OSType
  let manufacturerCode: OSType
  var architecture = PluginArchitecture.native
  /// Its bundle, when the system reports one.
  var url: URL?
  /// Has an arm64 build, so a native Live can load it.
  var isNative: Bool { architecture == .native }

  private enum CodingKeys: String, CodingKey {
    case name, manufacturer, typeCode, subTypeCode, manufacturerCode
  }

  /// FourCC strings (for display / .als serialization).
  var typeFourCC: String { AudioUnitCatalog.fourCC(typeCode) }
  var subTypeFourCC: String { AudioUnitCatalog.fourCC(subTypeCode) }
  var manufacturerFourCC: String { AudioUnitCatalog.fourCC(manufacturerCode) }

  var isInstrument: Bool { typeFourCC == "aumu" || typeFourCC == "augn" }

  static func == (a: AudioUnitInfo, b: AudioUnitInfo) -> Bool { a.id == b.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Discovers installed Audio Units via the system component registry — this is
/// how we get the real component codes (including the manufacturer code that a
/// VST3-only set can't provide).
enum AudioUnitCatalog {
  static func installed() -> [AudioUnitInfo] {
    let desc = AudioComponentDescription()  // all-zero => match everything
    let comps = AVAudioUnitComponentManager.shared().components(matching: desc)
    let bundles = componentBundles()
    return comps
      .map { c in
        let d = c.audioComponentDescription
        return AudioUnitInfo(
          name: c.name,
          manufacturer: c.manufacturerName,
          typeCode: d.componentType,
          subTypeCode: d.componentSubType,
          manufacturerCode: d.componentManufacturer,
          architecture: PluginArchitecture(c.availableArchitectures),
          url: bundles.byCodes[[d.componentType, d.componentSubType, d.componentManufacturer]]
            ?? bundles.byName[normalized(c.name)])
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// The `.component` bundles in the Components folders, by the codes each lists in
  /// its Info.plist, and by name for older ones that list none.
  /// (`AVAudioUnitComponent.componentURL` is deprecated.) App extension Audio Units
  /// have no bundle here.
  private static func componentBundles() -> (byCodes: [[OSType]: URL], byName: [String: URL]) {
    var byCodes: [[OSType]: URL] = [:]
    var byName: [String: URL] = [:]
    let home = FileManager.default.homeDirectoryForCurrentUser
    for dir in [URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components"),
                home.appendingPathComponent("Library/Audio/Plug-Ins/Components")] {
      let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
      for url in urls where url.pathExtension == "component" {
        byName[normalized(url.deletingPathExtension().lastPathComponent)] = url
        let components = Bundle(url: url)?.object(forInfoDictionaryKey: "AudioComponents") as? [[String: Any]] ?? []
        for component in components {
          let codes = ["type", "subtype", "manufacturer"].compactMap { (component[$0] as? String).flatMap(code) }
          if codes.count == 3 { byCodes[codes] = url }
        }
      }
    }
    return (byCodes, byName)
  }

  private static func normalized(_ name: String) -> String {
    String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
  }

  /// "aufx" → its OSType.
  private static func code(_ text: String) -> OSType? {
    let bytes = Array(text.utf8)
    guard bytes.count == 4 else { return nil }
    return bytes.reduce(0) { $0 << 8 | OSType($1) }
  }

  static func fourCC(_ code: OSType) -> String {
    let bytes = [
      UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
      UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
    ]
    return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 0x2e }, encoding: .ascii) ?? "????"
  }

  static func code(fromFourCC s: String) -> OSType {
    let bytes = Array(s.utf8.prefix(4))
    var code: OSType = 0
    for i in 0..<4 {
      code = (code << 8) | OSType(i < bytes.count ? bytes[i] : 0x20)
    }
    return code
  }
}
