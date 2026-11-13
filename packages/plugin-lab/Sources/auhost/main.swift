// auhost: offline AU host for calibration (built x86_64 so Intel-only AUs load under Rosetta).
//
//   auhost params <state.plist | type:sub:manu> [Name=value ...]
//   auhost save   <state.plist | type:sub:manu> <out.plist> [Name=value ...]
//   auhost render <state.plist | type:sub:manu> <in.wav> <out.wav> [Name=value ...]
//   auhost strings <state.plist | type:sub:manu> <Name> [steps]   # display text across the range
//
// Name=value sets a parameter (by display name, in its own units) after the state loads.
// A state plist is an AU ClassInfo dictionary (type/subtype/manufacturer + plugin data).
import AVFoundation
import AudioToolbox

setlinebuf(stdout)
let a = CommandLine.arguments
func code(_ s: String) -> UInt32 {
  if let n = UInt32(s) { return n }
  if let n = Int32(s) { return UInt32(bitPattern: n) }
  return s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}
var state: [String: Any]? = nil
let desc: AudioComponentDescription
if a[2].hasSuffix(".plist") {
  let p = try! PropertyListSerialization.propertyList(
    from: Data(contentsOf: URL(fileURLWithPath: a[2])), format: nil) as! [String: Any]
  state = p
  desc = AudioComponentDescription(
    componentType: (p["type"] as! NSNumber).uint32Value, componentSubType: (p["subtype"] as! NSNumber).uint32Value,
    componentManufacturer: (p["manufacturer"] as! NSNumber).uint32Value, componentFlags: 0, componentFlagsMask: 0)
} else {
  let c = a[2].split(separator: ":").map { code(String($0)) }
  desc = AudioComponentDescription(
    componentType: c[0], componentSubType: c[1], componentManufacturer: c[2], componentFlags: 0, componentFlagsMask: 0)
}
var unit: AVAudioUnit?
AVAudioUnit.instantiate(with: desc, options: .loadInProcess) { u, e in unit = u; if let e { print("instantiate:", e); exit(1) } }
while unit == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
let au = unit!
if let state { au.auAudioUnit.fullState = state }
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

let params = au.auAudioUnit.parameterTree?.allParameters ?? []
let overrideStart = ["params": 3, "save": 4, "strings": 99][a[1]] ?? 5
for o in a.dropFirst(overrideStart) {
  guard let eq = o.lastIndex(of: "=") else { continue }
  let name = String(o[..<eq]), value = Float(o[o.index(after: eq)...])!
  guard let p = params.first(where: { $0.displayName == name }) else { print("no parameter '\(name)'"); exit(2) }
  p.value = value
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

func dumpParams() {
  for p in params {
    let text = p.valueStrings.map { $0[min(max(Int(p.value), 0), $0.count - 1)] } ?? ""
    print("\(p.address)\t\(p.displayName)\t\(p.value)\t[\(p.minValue) … \(p.maxValue)]\tunit \(p.unit.rawValue)"
      + (p.unitName.map { " \($0)" } ?? "") + (text.isEmpty ? "" : "\t'\(text)'")
      + (p.valueStrings.map { "\t\($0)" } ?? ""))
  }
}

switch a[1] {
case "params":
  print("latency \(au.auAudioUnit.latency) s, tail \(au.auAudioUnit.tailTime) s, \(params.count) parameters")
  dumpParams()
case "strings":
  guard let p = params.first(where: { $0.displayName == a[3] }) else { print("no parameter '\(a[3])'"); exit(2) }
  let steps = a.count > 4 ? Int(a[4])! : 20
  for i in 0...steps {
    var v = p.minValue + (p.maxValue - p.minValue) * Float(i) / Float(steps)
    print("\(v)\t\(p.string(fromValue: &v))")
  }
case "save":
  let s = au.auAudioUnit.fullState ?? [:]
  try! PropertyListSerialization.data(fromPropertyList: s, format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: a[3]))
case "render":
  let sr = 48000.0
  let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
  let file = try! AVAudioFile(forReading: URL(fileURLWithPath: a[3]))
  let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
  try! file.read(into: src)
  let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
  let inBuf = AVAudioPCMBuffer(
    pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(file.length) * sr / file.processingFormat.sampleRate) + 4096)!
  var fed = false
  var err: NSError?
  conv.convert(to: inBuf, error: &err) { _, st in
    if fed { st.pointee = .endOfStream; return nil }
    fed = true; st.pointee = .haveData; return src
  }
  let engine = AVAudioEngine()
  let player = AVAudioPlayerNode()
  engine.attach(player); engine.attach(au)
  engine.connect(player, to: au, format: fmt)
  engine.connect(au, to: engine.mainMixerNode, format: fmt)
  try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
  try! engine.start()
  // Pre-roll silence so parameter smoothing settles; latency is compensated.
  let preroll = AVAudioFramePosition(sr * (Double(ProcessInfo.processInfo.environment["PREROLL"] ?? "1") ?? 1))
  let latency = AVAudioFramePosition((au.auAudioUnit.latency * sr).rounded())
  player.scheduleBuffer(inBuf, at: AVAudioTime(sampleTime: preroll, atRate: sr))
  player.play()
  let total = AVAudioFrameCount(inBuf.frameLength)
  var outFile: AVAudioFile? = try! AVAudioFile(
    forWriting: URL(fileURLWithPath: a[4]),
    settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
               AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
    commonFormat: .pcmFormatFloat32, interleaved: false)
  let blk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
  var done: AVAudioFrameCount = 0
  var skip = preroll + latency
  while done < total {
    let st = try! engine.renderOffline(512, to: blk)
    precondition(st == .success, "render \(st.rawValue)")
    let start = engine.manualRenderingSampleTime - AVAudioFramePosition(blk.frameLength)
    let from = max(0, skip - start)
    guard from < AVAudioFramePosition(blk.frameLength) else { continue }
    if from > 0 {
      let n = Int(blk.frameLength) - Int(from)
      for ch in 0..<Int(fmt.channelCount) {
        let d = blk.floatChannelData![ch]
        d.update(from: d + Int(from), count: n)
      }
      blk.frameLength = AVAudioFrameCount(n)
      skip = 0
    }
    try! outFile!.write(from: blk)
    done += blk.frameLength
  }
  outFile = nil
  engine.stop()
default:
  print("unknown command \(a[1])")
}
fflush(stdout)
_exit(0)
