import Foundation

/// The saved state of a VST2 device, as Live stores it under
/// `PluginDesc/VstPluginInfo/Preset/VstPreset`.
struct Vst2State {
  /// `FBCh` (opaque chunk) or `FxCk` (Live's own dump of program parameters).
  let type: String
  let uniqueId: Int32
  let pluginVersion: Int32
  let programCount: Int32
  let programNumber: Int32
  let buffer: Data

  var isChunk: Bool { type == "FBCh" }

  init?(device: XMLElement) {
    guard let info = device.firstChild("PluginDesc")?.firstChild("VstPluginInfo"),
          let preset = info.firstChild("Preset")?.firstChild("VstPreset"),
          let typeVal = preset.childValue("Type").flatMap(Int32.init),
          let type = DeviceExtractor.fourCC(Int(typeVal)),
          let uid = (preset.childValue("UniqueId") ?? info.childValue("UniqueId")).flatMap(Int32.init),
          let buffer = preset.firstChild("Buffer").flatMap({ Hex.decode($0.stringValue ?? "") })
    else { return nil }
    self.type = type
    self.uniqueId = uid
    self.pluginVersion = preset.childValue("PluginVersion").flatMap(Int32.init) ?? 1
    self.programCount = preset.childValue("ProgramCount").flatMap(Int32.init) ?? 1
    self.programNumber = preset.childValue("ProgramNumber").flatMap(Int32.init) ?? 0
    self.buffer = buffer
  }

  /// The preset type (`FBCh`, `FxBk`), without decoding its (possibly
  /// multi-megabyte) buffer.
  static func presetType(_ device: XMLElement) -> String? {
    device.firstChild("PluginDesc")?.firstChild("VstPluginInfo")?
      .firstChild("Preset")?.firstChild("VstPreset")?
      .childValue("Type").flatMap(Int.init).flatMap(DeviceExtractor.fourCC)
  }

  static func isChunkPreset(_ device: XMLElement) -> Bool { presetType(device) == "FBCh" }

  /// The current program's values from Live's `FxBk` dump, in VST2 index order.
  /// Live writes each program as a 28-byte name followed by its parameters as
  /// little-endian floats.
  func currentProgramParameters() -> [Float]? {
    guard type == "FxBk", programCount > 0, buffer.count % Int(programCount) == 0 else { return nil }
    let stride = buffer.count / Int(programCount)
    guard stride > 28, (stride - 28) % 4 == 0 else { return nil }
    let program = Int(programNumber >= 0 && programNumber < programCount ? programNumber : 0)
    let start = buffer.startIndex + program * stride + 28
    return Data.floats(buffer[start..<start + stride - 28], bigEndian: false)
  }

  /// The state a VST2-replacing VST3 accepts in `IComponent::setState`: a
  /// `VstW` header followed by a standard `CcnK`/`FBCh` bank wrapping the VST2
  /// chunk. This is byte-for-byte what a JUCE VST3 writes for itself (verified
  /// against AMBEO Orbit VST3 state in a real set). Only chunk presets can be
  /// wrapped this way.
  func vst3CompatibleState() -> Data? {
    guard isChunk else { return nil }
    var bank = Data()
    bank.appendBE(fourCC: "FBCh")
    bank.appendBE(Int32(2))  // fxBank version
    bank.appendBE(uniqueId)
    bank.appendBE(pluginVersion)
    bank.appendBE(Int32(0))  // numPrograms (JUCE writes 0 for chunk banks)
    bank.appendBE(programNumber)  // currentProgram
    bank.append(Data(count: 124))  // future
    bank.appendBE(Int32(buffer.count))
    bank.append(buffer)

    var out = Data()
    out.appendBE(fourCC: "VstW")
    out.appendBE(Int32(8))  // header size
    out.appendBE(Int32(1))  // version
    out.appendBE(Int32(0))  // bypass
    out.appendBE(fourCC: "CcnK")
    out.appendBE(Int32(bank.count))
    out.append(bank)
    return out
  }
}

/// A VST2 plugin's settings as the source device holds them, in a form its VST3
/// can be handed.
enum LegacyPreset {
  /// An opaque chunk, for VST3s that read VST2 chunks (JUCE's, Steinberg's wrapper).
  case chunk(Vst2State)
  /// Parameter values in VST2 index order: Live's `FxBk` dump of a VST2, or the
  /// `FxCk` program an Audio Unit built around a VST2 keeps (Xfer's do).
  case parameters([Float])

  init(device: Device) throws {
    switch device.format {
    case .vst:
      guard let state = Vst2State(device: device.element) else { throw Vst3MigrationError.noState }
      if state.isChunk {
        self = .chunk(state)
      } else if let values = state.currentProgramParameters() {
        self = .parameters(values)
      } else {
        throw Vst3MigrationError.unsupportedPreset(state.type)
      }
    case .au:
      self = .parameters(try Self.auParameters(device.element))
    default:
      throw Vst3MigrationError.notVst2
    }
  }

  /// An AU's state is a property list; one wrapping a VST2 stores that plugin's
  /// own program under `vstdata` as a standard `CcnK`/`FxCk` fxProgram.
  private static func auParameters(_ device: XMLElement) throws -> [Float] {
    guard let hex = device.firstChild("PluginDesc")?.firstChild("AuPluginInfo")?.firstChild("Preset")?
      .firstChild("AuPreset")?.firstChild("Buffer")?.stringValue,
      let buffer = Hex.decode(hex), !buffer.isEmpty,
      let plist = try? PropertyListSerialization.propertyList(from: buffer, format: nil) as? [String: Any]
    else { throw Vst3MigrationError.noState }
    guard let fx = plist["vstdata"] as? Data else { throw Vst3MigrationError.notWrappedVst2 }
    let bytes = [UInt8](fx)
    guard bytes.count >= 56, String(decoding: bytes[0..<4], as: UTF8.self) == "CcnK" else {
      throw Vst3MigrationError.noState
    }
    let magic = String(decoding: bytes[8..<12], as: UTF8.self)
    let count = Int(bytes[24..<28].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    guard magic == "FxCk", bytes.count >= 56 + count * 4 else { throw Vst3MigrationError.unsupportedPreset(magic) }
    return Data.floats(Data(bytes[56..<56 + count * 4]), bigEndian: true)
  }
}

enum Hex {
  static func decode(_ text: String) -> Data? {
    var out = Data()
    out.reserveCapacity(text.utf8.count / 2)
    var hi: UInt8?
    for c in text.utf8 {
      let v: UInt8
      switch c {
      case 0x30...0x39: v = c - 0x30
      case 0x41...0x46: v = c - 0x41 + 10
      case 0x61...0x66: v = c - 0x61 + 10
      case 0x20, 0x09, 0x0A, 0x0D: continue
      default: return nil
      }
      if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
    }
    return hi == nil ? out : nil
  }

  /// Uppercase hex in 80-character lines, as Live writes binary blobs.
  static func encodeLines(_ data: Data) -> [String] {
    let digits = Array("0123456789ABCDEF".utf8)
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: 40).map { start in
      var line = [UInt8]()
      line.reserveCapacity(80)
      for b in bytes[start..<min(start + 40, bytes.count)] {
        line.append(digits[Int(b >> 4)])
        line.append(digits[Int(b & 0xF)])
      }
      return String(decoding: line, as: UTF8.self)
    }
  }
}

extension Data {
  mutating func appendBE(_ v: Int32) {
    Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
  }

  mutating func appendBE(fourCC: String) {
    append(contentsOf: Array(fourCC.utf8.prefix(4)))
  }

  static func floats(_ data: Data, bigEndian: Bool) -> [Float] {
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count - 3, by: 4).map { i in
      let word = bytes[i..<i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      return Float(bitPattern: bigEndian ? word : word.byteSwapped)
    }
  }

  init(littleEndianFloats values: [Float]) {
    self.init()
    for v in values {
      Swift.withUnsafeBytes(of: v.bitPattern.littleEndian) { append(contentsOf: $0) }
    }
  }
}
