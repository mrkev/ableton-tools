import Foundation

/// Walks a Live Set's DOM to enumerate devices, and decodes plugin identity —
/// a Swift port of the `ableton-tools` TypeScript logic.
enum DeviceExtractor {
  static let rackTags: Set<String> = [
    "DrumGroupDevice", "InstrumentGroupDevice",
    "AudioEffectGroupDevice", "MidiEffectGroupDevice",
  ]

  private static let trackTags = [
    "MidiTrack", "AudioTrack", "ReturnTrack", "GroupTrack",
  ]

  // MARK: Extraction

  /// Every device across every track, in document order.
  static func extractAll(_ root: XMLElement) -> [Device] {
    var out: [Device] = []
    walkTracks(root) { track, name in
      collectDevices(in: track, depth: 0, trackName: name, into: &out)
    }
    return out
  }

  private static func walkTracks(_ node: XMLElement, _ visit: (XMLElement, String) -> Void) {
    for child in node.childElements {
      if trackTags.contains(child.name ?? "") {
        visit(child, trackName(child))
      } else {
        walkTracks(child, visit)
      }
    }
  }

  private static func trackName(_ track: XMLElement) -> String {
    if let nameNode = track.firstChild("Name") {
      if let n = nameNode.childValue("EffectiveName"), !n.isEmpty { return n }
      if let n = nameNode.childValue("UserName"), !n.isEmpty { return n }
    }
    return "(unnamed)"
  }

  private static func collectDevices(
    in node: XMLElement, depth: Int, trackName: String, into out: inout [Device]
  ) {
    for child in node.childElements {
      if child.name == "Devices" {
        for dev in child.childElements {
          out.append(Device(element: dev, parent: child, depth: depth, trackName: trackName))
          if rackTags.contains(dev.name ?? "") {
            collectDevices(in: dev, depth: depth + 1, trackName: trackName, into: &out)
          }
        }
      } else {
        collectDevices(in: child, depth: depth, trackName: trackName, into: &out)
      }
    }
  }

  // MARK: Format & identity

  static func detectFormat(_ dev: XMLElement, tag: String) -> DeviceFormat {
    if tag == "PluginDevice" {
      if let desc = dev.firstChild("PluginDesc"), desc.firstChild("Vst3PluginInfo") != nil {
        return .vst3
      }
      return .vst
    }
    switch tag {
    case "Vst3PluginDevice": return .vst3
    case "AuPluginDevice": return .au
    case "MxDeviceInstrument", "MxDeviceAudioEffect", "MxDeviceMidiEffect": return .m4l
    default: return .native
    }
  }

  static func deviceEnabled(_ dev: XMLElement) -> Bool {
    guard let on = dev.firstChild("On"), let v = on.childValue("Manual") else { return true }
    return v == "true"
  }

  struct PluginInfo {
    var product: String
    var category: DeviceCategory
    var vendor: String?
    var vstSdkVersion: String?
    var uniqueId: String?
    var auType: String?
    var auSubType: String?
    var auManufacturer: String?
    var vst3Uid: [Int32]?
  }

  static func pluginInfo(_ dev: XMLElement, format: DeviceFormat, tag: String) -> PluginInfo {
    switch format {
    case .native:
      let meta = nativeDevices[tag]
      return PluginInfo(product: meta?.name ?? deCamelCase(tag),
                        category: meta?.category ?? .unknown)

    case .m4l:
      let cat: DeviceCategory = tag == "MxDeviceInstrument" ? .instrument
        : tag == "MxDeviceMidiEffect" ? .midiEffect : .audioEffect
      return PluginInfo(product: "Max for Live", category: cat)

    case .au:
      let desc = dev.firstChild("PluginDesc")
      let info = desc?.firstChild("AuPluginInfo") ?? desc ?? dev
      let compType = numChild(info, "ComponentType")
      let subType = numChild(info, "ComponentSubType")
      let mfr = numChild(info, "ComponentManufacturer")
      return PluginInfo(
        product: info.childValue("Name") ?? "AU Plugin",
        category: compType.map { auRole(fourCC($0)) } ?? .unknown,
        vendor: info.childValue("Manufacturer"),
        uniqueId: subType.flatMap { fourCC($0) },
        auType: compType.flatMap { fourCC($0) },
        auSubType: subType.flatMap { fourCC($0) },
        auManufacturer: mfr.flatMap { fourCC($0) })

    case .vst3:
      let desc = dev.firstChild("PluginDesc")
      let info = desc?.firstChild("Vst3PluginInfo") ?? desc ?? dev
      let dt = numChild(info, "DeviceType")
      let uid = info.firstChild("Uid").map { uidNode -> [Int32] in
        (0..<4).compactMap { i in
          uidNode.childValue("Fields.\(i)").flatMap { Int32($0) }
        }
      }
      let cat: DeviceCategory = dt == 1 ? .instrument : (dt != nil ? .audioEffect : .unknown)
      return PluginInfo(product: info.childValue("Name") ?? "VST3 Plugin",
                        category: cat, vst3Uid: uid)

    case .vst:
      let desc = dev.firstChild("PluginDesc")
      let info = desc?.firstChild("VstPluginInfo") ?? desc ?? dev
      let cat = numChild(info, "Category")
      let ver = numChild(info, "VstVersion")
      let uid = numChild(info, "UniqueId")
      return PluginInfo(
        product: info.childValue("PlugName") ?? info.childValue("Name") ?? "VST Plugin",
        category: cat.map(vst2Role) ?? .unknown,
        vstSdkVersion: ver.map(formatVstVersion),
        uniqueId: uid.flatMap { fourCC($0) } ?? uid.map(String.init))
    }
  }

  // MARK: Helpers

  private static func numChild(_ node: XMLElement, _ name: String) -> Int? {
    node.childValue(name).flatMap { Int($0) }
  }

  /// Decode a 32-bit int as a printable four-character code, else nil.
  static func fourCC(_ n: Int) -> String? {
    let u = UInt32(bitPattern: Int32(truncatingIfNeeded: n))
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff),
                 UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
    return String(bytes: bytes, encoding: .ascii)
  }

  private static func auRole(_ code: String?) -> DeviceCategory {
    switch code {
    case "aumu", "augn": return .instrument
    case "aufx", "aumf": return .audioEffect
    case "aumi": return .midiEffect
    default: return .unknown
    }
  }

  private static func vst2Role(_ category: Int) -> DeviceCategory {
    switch category {
    case 2, 11: return .instrument
    case 1, 3, 4, 5, 6, 7, 8, 9: return .audioEffect
    default: return .unknown
    }
  }

  private static func formatVstVersion(_ v: Int) -> String {
    "\(v / 1000).\((v % 1000) / 100)"
  }

  private static func deCamelCase(_ s: String) -> String {
    var out = ""
    let chars = Array(s)
    for (i, c) in chars.enumerated() {
      if i > 0, c.isUppercase, !chars[i - 1].isUppercase { out.append(" ") }
      out.append(c)
    }
    return out
  }

  static let nativeDevices: [String: (name: String, category: DeviceCategory)] = [
    // Instruments
    "Operator": ("Operator", .instrument),
    "InstrumentVector": ("Wavetable", .instrument),
    "MultiSampler": ("Sampler", .instrument),
    "OriginalSimpler": ("Simpler", .instrument),
    "Impulse": ("Impulse", .instrument),
    "UltraAnalog": ("Analog", .instrument),
    "Collision": ("Collision", .instrument),
    "StringStudio": ("Tension", .instrument),
    "LoungeLizard": ("Electric", .instrument),
    "Drift": ("Drift", .instrument),
    "Meld": ("Meld", .instrument),
    "ExternalInstrument": ("External Instrument", .instrument),
    "DrumGroupDevice": ("Drum Rack", .instrument),
    "InstrumentGroupDevice": ("Instrument Rack", .instrument),
    // Audio effects
    "Eq8": ("EQ Eight", .audioEffect),
    "FilterEQ3": ("EQ Three", .audioEffect),
    "Compressor2": ("Compressor", .audioEffect),
    "Glue": ("Glue Compressor", .audioEffect),
    "Limiter": ("Limiter", .audioEffect),
    "MultibandDynamics": ("Multiband Dynamics", .audioEffect),
    "Gate": ("Gate", .audioEffect),
    "Saturator": ("Saturator", .audioEffect),
    "Overdrive": ("Overdrive", .audioEffect),
    "Tube": ("Dynamic Tube", .audioEffect),
    "Erosion": ("Erosion", .audioEffect),
    "Reverb": ("Reverb", .audioEffect),
    "HybridReverb": ("Hybrid Reverb", .audioEffect),
    "Echo": ("Echo", .audioEffect),
    "Delay": ("Delay", .audioEffect),
    "PingPongDelay": ("Ping Pong Delay", .audioEffect),
    "FilterDelay": ("Filter Delay", .audioEffect),
    "GrainDelay": ("Grain Delay", .audioEffect),
    "Phaser": ("Phaser", .audioEffect),
    "Flanger": ("Flanger", .audioEffect),
    "Chorus": ("Chorus", .audioEffect),
    "AutoPan": ("Auto Pan", .audioEffect),
    "AutoFilter": ("Auto Filter", .audioEffect),
    "StereoGain": ("Utility", .audioEffect),
    "Tuner": ("Tuner", .audioEffect),
    "Spectrum": ("Spectrum", .audioEffect),
    "Resonator": ("Resonators", .audioEffect),
    "Vocoder": ("Vocoder", .audioEffect),
    "Corpus": ("Corpus", .audioEffect),
    "DrumBuss": ("Drum Buss", .audioEffect),
    "Pedal": ("Pedal", .audioEffect),
    "Roar": ("Roar", .audioEffect),
    "AudioEffectGroupDevice": ("Audio Effect Rack", .audioEffect),
    // MIDI effects
    "MidiArpeggiator": ("Arpeggiator", .midiEffect),
    "MidiChord": ("Chord", .midiEffect),
    "MidiPitcher": ("Pitch", .midiEffect),
    "MidiScale": ("Scale", .midiEffect),
    "MidiVelocity": ("Velocity", .midiEffect),
    "NoteLength": ("Note Length", .midiEffect),
    "MidiRandom": ("Random", .midiEffect),
    "MidiEffectGroupDevice": ("MIDI Effect Rack", .midiEffect),
  ]
}
