import AVFoundation
import Foundation

/// An Audio Unit installed on this Mac, with the component codes Ableton needs.
struct AudioUnitInfo: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let manufacturer: String
  let typeCode: OSType
  let subTypeCode: OSType
  let manufacturerCode: OSType

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
    return comps
      .map { c in
        let d = c.audioComponentDescription
        return AudioUnitInfo(
          name: c.name,
          manufacturer: c.manufacturerName,
          typeCode: d.componentType,
          subTypeCode: d.componentSubType,
          manufacturerCode: d.componentManufacturer)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
