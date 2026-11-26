import Foundation

/// Replaces FabFilter Pro-C (Intel only) with Pro-C 2. Opt-in, because it isn't
/// a bit-exact match.
///
/// Pro-C 2 can't read Pro-C's state, but it has the same three styles (Clean,
/// Classic, Opto) and most of the same controls, so each setting is translated.
/// Where the two differ, the translation was measured by rendering both plugins
/// offline (`Calibration/ProCToProC2`):
///
/// - Pro-C's soft knee is Pro-C 2's 24 dB knee; Classic needs its ratio 0.02 higher.
/// - Attack and release run on different curves (Pro-C: 0.5–500 ms and 50–5000 ms,
///   Pro-C 2: 0.005–250 ms and 10–2500 ms), and the same milliseconds don't
///   behave the same. The times that sound closest were fitted on program
///   material, per style, with and without auto release (Pro-C's auto release has
///   a speed control Pro-C 2 lacks).
/// - Pro-C 2's Auto Gain works out a different makeup, so it's turned off and
///   Pro-C's own makeup (which shrinks for slow attacks) is added to the wet gain.
/// - Pro-C's expert side chain mixes each detector between left and right; that's
///   Pro-C 2's stereo link. Its side-chain filters sit half an octave off Pro-C 2's.
///
/// Pro-C 2 has no mid/side processing, and its attack stops at 250 ms; devices
/// using either get a note.
enum ProCToProC2 {
  static let targetName = "FabFilter Pro-C 2"
  static let defaultsKey = "substituteProC"

  static let auType: Int32 = 1_635_085_670  // 'aumf'
  static let proCSubType: Int32 = 1_179_677_251  // 'FPrC'
  static let fabFilter: Int32 = 1_180_787_270  // 'FabF'
  static let proC2SubType: Int32 = 1_178_808_944  // 'FC2p'

  static func isProC(_ p: LiveSetScan.AuPlugin) -> Bool {
    p.subType == proCSubType && p.manufacturer == fabFilter
  }

  static func isProC(_ device: Device) -> Bool {
    LiveSetScan.AuPlugin(device: device).map(isProC) ?? false
  }

  /// Pro-C 2's AU, for a Pro-C AU. (Pro-C only appears as an AU.)
  static func target(for format: DeviceFormat, audioUnits: [AudioUnitInfo]) -> PluginTarget? {
    guard format == .au else { return nil }
    return audioUnits.first {
      $0.isNative && Int32(bitPattern: $0.subTypeCode) == proC2SubType
        && Int32(bitPattern: $0.manufacturerCode) == fabFilter
    }.map(PluginTarget.au)
  }

  // MARK: Settings

  /// Pro-C's parameters, by their index in its state (its AU parameter addresses).
  enum P: Int, CaseIterable {
    case characteristic, threshold, ratio, kneeShape, attack, release, inputLevel, inputPanning
    case leftSideChainLevel, leftSideChainMix, rightSideChainLevel, rightSideChainMix
    case outputLevel, outputPanning, dryLevel, dryPanning, autoGain, autoRelease, autoReleaseSpeed
    case inputSignal, lowPassFrequency, highPassFrequency, auditionSideChain, channelProcessing
    case receiveMidi, expertMode
  }

  /// Pro-C keeps its settings as `data`: a 12-byte header, then (index, value)
  /// pairs of big-endian UInt32 and Float32, in its own units.
  static func settings(of device: Device) throws -> [P: Float] {
    guard let data = AuRetarget.state(of: device)?["data"] as? Data, data.count >= 12 else {
      throw ProCError.noState
    }
    let bytes = [UInt8](data)
    var out: [P: Float] = [:]
    for at in stride(from: 12, to: bytes.count - 7, by: 8) {
      let word = { (o: Int) in bytes[o..<o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
      if let p = P(rawValue: Int(word(at))) { out[p] = Float(bitPattern: word(at + 4)) }
    }
    let missing = P.allCases.filter { out[$0] == nil }
    guard missing.isEmpty else { throw ProCError.incompleteState(missing.map { "\($0)" }.joined(separator: ", ")) }
    return out
  }

  /// FabFilter's level scale (Pro-C's output and dry, Pro-C 2's wet and dry): 36 dB
  /// per unit above -0.5, falling to -inf at -1.
  private static func levelDb(_ x: Float) -> Double { Double(x) * 36 }
  private static func level(_ db: Double) -> Float { Float(db / 36) }

  /// Pro-C's side-chain filter frequencies: 5 Hz at 0 to 30 kHz at 1, logarithmic.
  private static func filterHz(_ x: Float) -> Double { 5 * pow(6000, Double(x)) }

  /// Pro-C 2's settings (by parameter name, in its own units) for a Pro-C device,
  /// and anything that couldn't carry over.
  static func translate(_ v: [P: Float]) -> (values: [String: Float], notes: [String]) {
    let style = Int(v[.characteristic]!.rounded())
    let hardKnee = v[.kneeShape]! >= 0.5
    let autoRelease = v[.autoRelease]! >= 0.5
    let expert = v[.expertMode]! >= 0.5
    var notes: [String] = []

    let timing = autoRelease
      ? ProCTables.autoTiming(style: style, attack: Double(v[.attack]!), speed: Double(v[.autoReleaseSpeed]!))
      : ProCTables.manualTiming(style: style, attack: Double(v[.attack]!), release: Double(v[.release]!))
    if timing.attackMs > 250 { notes.append("its attack is longer than Pro-C 2's 250 ms maximum") }

    var wet = v[.outputLevel]!
    if v[.autoGain]! >= 0.5 {
      let makeup = ProCTables.makeupDb(
        style: style, hardKnee: hardKnee, threshold: Double(v[.threshold]!), ratio: Double(v[.ratio]!),
        attack: Double(v[.attack]!))
      wet = level(levelDb(wet) + makeup)
    }

    var out: [String: Float] = [
      "Style": Float(style),
      "Threshold": v[.threshold]!,
      "Ratio": min(1, v[.ratio]! + (style == 1 ? 0.02 : 0)),
      "Knee": hardKnee ? 0 : 24,
      "Range": 60,
      "Attack": Float(ProCTables.proC2Attack(ms: timing.attackMs)),
      "Release": Float(ProCTables.proC2Release(ms: timing.releaseMs)),
      "Auto Release": autoRelease ? 1 : 0,
      "Lookahead Enabled": 0, "Lookahead": 0, "Hold": 0,
      "Input Level": v[.inputLevel]!, "Input Pan": v[.inputPanning]!,
      "Output Level": 0, "Output Pan": 0, "Mix": 1,
      "Wet Gain": wet, "Wet Pan": v[.outputPanning]!,
      "Dry Gain": v[.dryLevel]!, "Dry Pan": v[.dryPanning]!,
      // Pro-C 2's own makeup differs; Pro-C's is in the wet gain.
      "Auto Gain": 0,
      "Side Chain Input": v[.inputSignal]! >= 0.5 ? 1 : 0,
      "Side Chain Expert Mode": expert ? 1 : 0,
      "Audition Side Chain": 0,
      "Midi State": v[.receiveMidi]! >= 0.5 ? 1 : 0,
      "Oversampling": 0,
      "Side Chain Mid Enabled": 0,
    ]
    // Pro-C's expert side chain: each detector's level, and its mix between the
    // left and right inputs (-1 left … 1 right). Detectors that each hear their own
    // side are Pro-C 2's stereo link at 0%; both hearing the sum is 100%.
    if expert {
      let left = v[.leftSideChainMix]!, right = v[.rightSideChainMix]!
      out["Stereo Link"] = Float(ProCTables.linkPercent(spread: Double(max(0, min(1, (right - left) / 2)))) / 200)
      let levels = (v[.leftSideChainLevel]!, v[.rightSideChainLevel]!)
      out["Side Chain Level"] = (levels.0 + levels.1) / 2
      if abs(levels.0 - levels.1) > 1 {
        notes.append(String(format: "its side-chain levels differ per channel (%+.1f / %+.1f dB); Pro-C 2 has one",
                            levels.0, levels.1))
      }
      if abs(left + right) > 0.1 {
        notes.append("its side chain mixes left and right unevenly; Pro-C 2's stereo link is symmetric")
      }
      // Fitted: Pro-C 2's high-pass half an octave higher at 30 dB/oct, its
      // low-pass half an octave lower at 36 dB/oct.
      let hp = v[.highPassFrequency]!, lp = v[.lowPassFrequency]!
      out["Side Chain Low Enabled"] = hp > 0.001 ? 1 : 0
      out["Side Chain Low Frequency"] = Float(clampLog2(log2(filterHz(hp)) + 0.5))
      out["Side Chain Low Slope"] = 4
      out["Side Chain High Enabled"] = lp < 0.999 ? 1 : 0
      out["Side Chain High Frequency"] = Float(clampLog2(log2(filterHz(lp)) - 0.5))
      out["Side Chain High Slope"] = 5
    }
    if v[.channelProcessing]! >= 0.5 {
      notes.append("it compresses mid and side separately, which Pro-C 2 can't, so it may sound different")
    }
    if v[.inputSignal]! >= 0.5 { notes.append("it's keyed from an external side chain; check its routing in Live") }
    return (out, notes)
  }

  private static func clampLog2(_ x: Double) -> Double { min(max(x, 4.321928), 14.287712) }

  // MARK: Conversion

  @MainActor
  static func convert(_ device: Device, target: PluginTarget, automatedTargets: Set<String>) async throws
    -> SubstitutionResult
  {
    guard isProC(device) else { throw ProCError.notProC }
    guard case .au(let au) = target else { throw ProCError.unexpectedLayout }
    let source = try settings(of: device)
    var (values, notes) = translate(source)
    let (state, parameters) = try await AuHost.load(au, values: values)

    // Read every value back: a name Pro-C 2 doesn't know, or a value it clamps,
    // shows up here.
    let byName = Dictionary(parameters.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    for (name, want) in values {
      guard let got = byName[name]?.value else { throw ProCError.settingsNotCarried("no '\(name)'") }
      if abs(got - want) > 1e-3 * max(1, abs(want)) {
        // A level beyond the scale's range is the only expected clamp.
        guard name == "Wet Gain" else {
          throw ProCError.settingsNotCarried(String(format: "'%@' is %.4g, not %.4g", name, got, want))
        }
        notes.append(String(format: "its output gain is beyond Pro-C 2's range, so it's %.1f dB quieter",
                            levelDb(want) - levelDb(got)))
        values[name] = got
      }
    }

    let slots = slotPlan(device, parameters: byName, automated: automatedTargets, notes: &notes)
    guard let replacement = try? AuRetarget.build(
      from: device, to: au, state: state, parameterCount: parameters.count, slots: slots,
      renameReferences: renameReferences) else { throw ProCError.unexpectedLayout }
    return SubstitutionResult(replacement: replacement, follower: nil, detail: "settings translated", notes: notes)
  }

  /// Pro-C's slots, by its parameter name, to Pro-C 2's. Those without a
  /// counterpart are unbound.
  private static let slotTargets: [String: String] = [
    "Characteristic": "Style", "Threshold": "Threshold", "Ratio": "Ratio", "Knee Shape": "Knee",
    "Attack": "Attack", "Release": "Release", "Input Level": "Input Level", "Input Panning": "Input Pan",
    "Left Side Chain Level": "Side Chain Level", "Left Side Chain Mix": "Stereo Link",
    "Output Level": "Wet Gain", "Output Panning": "Wet Pan", "Dry Level": "Dry Gain", "Dry Panning": "Dry Pan",
    "Auto Gain": "Auto Gain", "Auto Release": "Auto Release", "Input signal": "Side Chain Input",
    "Low Pass Frequency": "Side Chain High Frequency", "High Pass Frequency": "Side Chain Low Frequency",
    "Audition Side Chain": "Audition Side Chain", "Receive Midi": "Midi State",
    "Expert Mode": "Side Chain Expert Mode",
  ]

  /// Each configured slot points at its Pro-C 2 counterpart, showing Pro-C 2's
  /// value. Automation is dropped: Pro-C 2's ranges differ, so an envelope
  /// wouldn't mean the same thing.
  private static func slotPlan(
    _ device: Device, parameters: [String: AuParameter], automated: Set<String>, notes: inout [String]
  ) -> [ParameterSlots.Change] {
    guard let list = device.element.firstChild("ParameterList") else { return [] }
    let slots = Vst3Migration.configuredSlots(device.element)
    var out: [ParameterSlots.Change] = []
    var unbound: [String] = []
    for (position, element) in list.childElements.enumerated() {
      guard let slot = slots.first(where: { $0.element === element }) else { continue }
      let isAutomated = slot.hasInlineAutomation || slot.automationTarget.map(automated.contains) == true
      guard !isAutomated, let name = slotTargets[slot.name], let p = parameters[name] else {
        if isAutomated { unbound.append(slot.name) }
        out.append(ParameterSlots.Change(position: position, id: -1, name: "", manual: nil))
        continue
      }
      out.append(ParameterSlots.Change(
        position: position, id: Int32(truncatingIfNeeded: p.address), name: p.name, manual: p.normalized))
    }
    if !unbound.isEmpty {
      notes.append("automation of \(unbound.joined(separator: ", ")) is dropped; Pro-C 2's ranges differ")
    }
    return out
  }

  /// `query:Find#FF%20Pro-C` and the like.
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
        let renamed = v == "FF Pro-C" ? "Pro-C 2"
          : v.replacingOccurrences(of: "FF%20Pro-C", with: "Pro-C%202")
        if renamed != v { attribute.stringValue = renamed }
      }
      stack += e.childElements
    }
  }
}

enum ProCError: Error, CustomStringConvertible {
  case notProC
  case noState
  case incompleteState(String)
  case settingsNotCarried(String)
  case unexpectedLayout

  var description: String {
    switch self {
    case .notProC: return "not a FabFilter Pro-C device"
    case .noState: return "no readable Pro-C settings in the set"
    case .incompleteState(let what): return "Pro-C's saved settings lack \(what)"
    case .settingsNotCarried(let what): return "settings didn't carry over: \(what)"
    case .unexpectedLayout: return "the device isn't laid out as expected"
    }
  }
}
