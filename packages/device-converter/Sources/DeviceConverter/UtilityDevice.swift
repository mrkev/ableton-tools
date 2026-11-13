import Foundation

/// Builds Live's Utility (`StereoGain`) device, for a fixed gain change.
///
/// The template is a Utility as Live 10 and 11 save it, with its browser
/// references cleared (Live writes `<Value />` for those itself). Live 11 adds
/// `ModulationSourceCount` and a `Pointee`.
enum UtilityDevice {
  /// The most gain Utility allows: +35 dB.
  static let maxGainDb = 35.0

  static func make(gainDb: Double, isOn: Bool, name: String, document: AlsDocument) throws -> XMLElement {
    let isLive11 = LiveVersion.major(creator: document.creator).map { $0 >= 11 } ?? true
    var text = template
      .replacingOccurrences(of: "{LIVE11_SOURCES}", with: isLive11 ? #"<ModulationSourceCount Value="0" />"# : "")
      .replacingOccurrences(of: "{LIVE11_POINTEE}", with: isLive11 ? #"<Pointee Id="{ID}" />"# : "")
      .replacingOccurrences(of: "{OVERWRITE_PROTECTION}", with: isLive11 ? "2817" : "2561")
      .replacingOccurrences(of: "{ON}", with: isOn ? "true" : "false")
      .replacingOccurrences(of: "{NAME}", with: name.xmlEscaped)
      .replacingOccurrences(of: "{GAIN}", with: String(pow(10, min(gainDb, maxGainDb) / 20)))
    var ids = try PointeeIds(document)
    while let r = text.range(of: "{ID}") { text.replaceSubrange(r, with: String(ids.next())) }
    ids.commit()
    return try XMLElement.parsed(text)
  }

  private static let template = """
    <StereoGain Id="0"><LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" /><On><LomId Value="0" />\
    <Manual Value="{ON}" /><AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget>\
    <MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds></On>{LIVE11_SOURCES}\
    <ParametersListWrapper LomId="0" />{LIVE11_POINTEE}<LastSelectedTimeableIndex Value="0" />\
    <LastSelectedClipEnvelopeIndex Value="0" /><LastPresetRef><Value /></LastPresetRef><LockedScripts />\
    <IsFolded Value="false" /><ShouldShowPresetName Value="true" /><UserName Value="{NAME}" />\
    <Annotation Value="" /><SourceContext><Value /></SourceContext>\
    <OverwriteProtectionNumber Value="{OVERWRITE_PROTECTION}" />\
    <PhaseInvertL><LomId Value="0" /><Manual Value="false" /><AutomationTarget Id="{ID}"><LockEnvelope Value="0" />\
    </AutomationTarget><MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>\
    </PhaseInvertL><PhaseInvertR><LomId Value="0" /><Manual Value="false" /><AutomationTarget Id="{ID}">\
    <LockEnvelope Value="0" /></AutomationTarget><MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" />\
    </MidiCCOnOffThresholds></PhaseInvertR><ChannelMode><LomId Value="0" /><Manual Value="1" />\
    <AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget></ChannelMode><StereoWidth>\
    <LomId Value="0" /><Manual Value="1" /><MidiControllerRange><Min Value="0" /><Max Value="4" />\
    </MidiControllerRange><AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget>\
    <ModulationTarget Id="{ID}"><LockEnvelope Value="0" /></ModulationTarget></StereoWidth><MidSideBalance>\
    <LomId Value="0" /><Manual Value="1" /><MidiControllerRange><Min Value="0" /><Max Value="2" />\
    </MidiControllerRange><AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget>\
    <ModulationTarget Id="{ID}"><LockEnvelope Value="0" /></ModulationTarget></MidSideBalance>\
    <MidSideBalanceOn Value="false" /><Mono><LomId Value="0" /><Manual Value="false" /><AutomationTarget Id="{ID}">\
    <LockEnvelope Value="0" /></AutomationTarget><MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" />\
    </MidiCCOnOffThresholds></Mono><BassMono><LomId Value="0" /><Manual Value="false" />\
    <AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget><MidiCCOnOffThresholds>\
    <Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds></BassMono><BassMonoAudition Value="false" />\
    <BassMonoFrequency><LomId Value="0" /><Manual Value="120" /><MidiControllerRange><Min Value="50" />\
    <Max Value="500" /></MidiControllerRange><AutomationTarget Id="{ID}"><LockEnvelope Value="0" />\
    </AutomationTarget><ModulationTarget Id="{ID}"><LockEnvelope Value="0" /></ModulationTarget>\
    </BassMonoFrequency><Balance><LomId Value="0" /><Manual Value="0" /><MidiControllerRange><Min Value="-1" />\
    <Max Value="1" /></MidiControllerRange><AutomationTarget Id="{ID}"><LockEnvelope Value="0" />\
    </AutomationTarget><ModulationTarget Id="{ID}"><LockEnvelope Value="0" /></ModulationTarget></Balance><Gain>\
    <LomId Value="0" /><Manual Value="{GAIN}" /><MidiControllerRange><Min Value="0" /><Max Value="56.2341309" />\
    </MidiControllerRange><AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget>\
    <ModulationTarget Id="{ID}"><LockEnvelope Value="0" /></ModulationTarget></Gain><LegacyGain><LomId Value="0" />\
    <Manual Value="0" /><MidiControllerRange><Min Value="-35" /><Max Value="35" /></MidiControllerRange>\
    <AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget><ModulationTarget Id="{ID}">\
    <LockEnvelope Value="0" /></ModulationTarget></LegacyGain><Mute><LomId Value="0" /><Manual Value="false" />\
    <AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget><MidiCCOnOffThresholds>\
    <Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds></Mute><DcFilter><LomId Value="0" />\
    <Manual Value="false" /><AutomationTarget Id="{ID}"><LockEnvelope Value="0" /></AutomationTarget>\
    <MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds></DcFilter>\
    <LegacyMode Value="false" /></StereoGain>
    """
}

/// Hands out new automation, modulation and pointee ids. Live keeps the next free
/// one in `LiveSet/NextPointeeId`, above every id in the set.
struct PointeeIds {
  private let counter: XMLElement
  private var value: Int

  init(_ document: AlsDocument) throws {
    guard let counter = document.root.firstChild("LiveSet")?.firstChild("NextPointeeId"),
          let value = counter.valueAttr.flatMap(Int.init) else { throw UtilityError.noIdCounter }
    self.counter = counter
    self.value = value
  }

  mutating func next() -> Int {
    defer { value += 1 }
    return value
  }

  func commit() {
    counter.attribute(forName: "Value")?.stringValue = String(value)
  }
}

enum UtilityError: Error, CustomStringConvertible {
  case noIdCounter
  var description: String { "the set has no NextPointeeId to number a new device from" }
}

extension String {
  var xmlEscaped: String {
    replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}
