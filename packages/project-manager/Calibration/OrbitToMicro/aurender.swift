// aurender <state.plist> <in.wav> <out.wav> [param_x=value ...]
// Hosts the AU named by the plist offline at 48 kHz, applies the JUCE state with overrides.
import AVFoundation
import AudioToolbox

let a = CommandLine.arguments
let plist = try! PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: a[1])), format: nil) as! [String: Any]
var state = plist
var juce = plist["jucePluginState"] as! Data
var xml = String(decoding: juce[8..<(8 + Int(juce[4]) + Int(juce[5]) << 8)], as: UTF8.self)
for o in a.dropFirst(4) {
  let kv = o.split(separator: "=").map(String.init)
  let re = try! NSRegularExpression(pattern: "(id=\"\(kv[0])\" value=\")[^\"]*\"")
  precondition(re.numberOfMatches(in: xml, range: NSRange(xml.startIndex..., in: xml)) == 1, "no \(kv[0])")
  xml = re.stringByReplacingMatches(in: xml, range: NSRange(xml.startIndex..., in: xml), withTemplate: "$1\(kv[1])\"")
}
var out = Data("VC2!".utf8)
var len = UInt32(xml.utf8.count).littleEndian
out.append(Data(bytes: &len, count: 4)); out.append(Data(xml.utf8)); out.append(0)
state["jucePluginState"] = out

let desc = AudioComponentDescription(
  componentType: (plist["type"] as! NSNumber).uint32Value, componentSubType: (plist["subtype"] as! NSNumber).uint32Value,
  componentManufacturer: (plist["manufacturer"] as! NSNumber).uint32Value, componentFlags: 0, componentFlagsMask: 0)
var unit: AVAudioUnit?
AVAudioUnit.instantiate(with: desc, options: .loadInProcess) { u, e in unit = u; if let e { print("instantiate:", e) } }
while unit == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
let au = unit!
au.auAudioUnit.fullState = state
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

let sr = 48000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
let file = try! AVAudioFile(forReading: URL(fileURLWithPath: a[2]))
let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try! file.read(into: src)
let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(file.length) * sr / file.processingFormat.sampleRate) + 4096)!
var fed = false
var err: NSError?
conv.convert(to: inBuf, error: &err) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return src }

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player); engine.attach(au)
engine.connect(player, to: au, format: fmt)
engine.connect(au, to: engine.mainMixerNode, format: fmt)
try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
try! engine.start()
let preroll = AVAudioFramePosition(sr * (Double(ProcessInfo.processInfo.environment["PREROLL"] ?? "2") ?? 2))
player.scheduleBuffer(inBuf, at: AVAudioTime(sampleTime: preroll, atRate: sr))
player.play()
let total = AVAudioFrameCount(sr * 1.0)
var outFile: AVAudioFile? = try! AVAudioFile(forWriting: URL(fileURLWithPath: a[3]), settings: fmt.settings)
let blk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
var done: AVAudioFrameCount = 0
while done < total {
  let st = try! engine.renderOffline(512, to: blk)
  precondition(st == .success, "render \(st.rawValue)")
  if engine.manualRenderingSampleTime > preroll { try! outFile!.write(from: blk); done += blk.frameLength }
}
print("latency", au.auAudioUnit.latency, "params", au.auAudioUnit.parameterTree?.allParameters.map { "\($0.displayName)=\($0.value)" }.joined(separator: " ") ?? "")
outFile = nil; engine.stop(); fflush(stdout); _exit(0)
