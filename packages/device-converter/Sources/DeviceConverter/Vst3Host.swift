import CVst3Host
import Foundation

/// An installed VST3 audio-module class.
struct Vst3PluginInfo: Hashable, Codable {
  let bundleURL: URL
  /// 16-byte class id (TUID), as the factory reports it.
  let cid: [UInt8]
  let name: String
  let category: String

  /// The four big-endian int32 words Live stores as `<Uid><Fields.N>`.
  var uidFields: [Int32] { Vst3Uid.fields(cid) }
}

enum Vst3Uid {
  /// Steinberg's VST2-compatible class id: "VST" + the VST2 unique id (4
  /// bytes) + the first 9 characters of the lowercased plugin name,
  /// zero-padded to 16 bytes. Plugins that are meant to replace their VST2
  /// build (JUCE's `JUCE_VST3_CAN_REPLACE_VST2`, Steinberg's own wrapper) use it.
  static func vst2Compatible(uniqueId: Int32, name: String) -> [UInt8] {
    var out = Array("VST".utf8)
    out += withUnsafeBytes(of: UInt32(bitPattern: uniqueId).bigEndian) { Array($0) }
    out += Array(name.lowercased().utf8.prefix(9))
    out += Array(repeating: 0, count: 16 - out.count)
    return out
  }

  static func fields(_ cid: [UInt8]) -> [Int32] {
    (0..<4).map { i in
      Int32(bitPattern: cid[(i * 4)..<(i * 4 + 4)].reduce(0) { $0 << 8 | UInt32($1) })
    }
  }

  /// `56535453-6541-4f61-6d62-656f206f7262` — the form Live uses in
  /// `BranchDeviceId` (`device:vst3:<role>:<uuid>`).
  static func uuidString(_ cid: [UInt8]) -> String {
    let hex = cid.map { String(format: "%02x", $0) }.joined()
    let cuts = [8, 12, 16, 20]
    var out = ""
    for (i, c) in hex.enumerated() {
      if cuts.contains(i) { out.append("-") }
      out.append(c)
    }
    return out
  }
}

enum Vst3Catalog {
  static let searchDirectories = [
    URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3"),
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3"),
  ]

  /// Every audio-module class in every installed `.vst3` bundle that loads in
  /// this process. Bundles without a slice for this CPU are skipped — which is
  /// exactly the filter we want: a native Live can't load them either.
  static func installed() -> [Vst3PluginInfo] {
    bundles().flatMap(classes(in:))
  }

  /// Loads the bundle's code, so call this on the main thread (plugins expect it).
  static func classes(in bundle: URL) -> [Vst3PluginInfo] {
    var out: [Vst3PluginInfo] = []
    var classes = [v3_class_info](repeating: v3_class_info(), count: 64)
    let n = Int(v3_list_classes(bundle.path, &classes, Int32(classes.count)))
    guard n > 0 else { return [] }
    for var c in classes.prefix(min(n, classes.count)) {
      let category = withUnsafeBytes(of: &c.category) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
      guard category == "Audio Module Class" else { continue }
      let name = withUnsafeBytes(of: &c.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
      let cid = withUnsafeBytes(of: &c.cid) { Array($0) }
      out.append(Vst3PluginInfo(bundleURL: bundle, cid: cid, name: name, category: category))
    }
    return out
  }

  static func bundles() -> [URL] {
    let fm = FileManager.default
    var out: [URL] = []
    for dir in searchDirectories {
      guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in e where url.pathExtension == "vst3" {
        out.append(url)
        e.skipDescendants()
      }
    }
    return out
  }
}

/// A live instance of a VST3 plugin, hosted offline (no audio).
final class Vst3Instance {
  struct Parameter {
    let id: UInt32
    let title: String
    let normalized: Double
  }

  private let handle: OpaquePointer

  init(_ plugin: Vst3PluginInfo) throws {
    var err = [CChar](repeating: 0, count: 256)
    guard let h = plugin.cid.withUnsafeBufferPointer({
      v3_open(plugin.bundleURL.path, $0.baseAddress, &err, err.count)
    }) else {
      throw Vst3Error.open(plugin.name, String(cString: err))
    }
    handle = h
  }

  deinit { v3_close(handle) }

  /// Load a state blob, give the plugin's main-thread work (JUCE applies some
  /// of it asynchronously) a chance to run, then sync the controller.
  func setState(_ data: Data) throws {
    let r = data.withUnsafeBytes { v3_set_state(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    if r != 0 { throw Vst3Error.setState(r) }
    Self.pumpMainRunLoop()
    v3_sync_controller(handle)
  }

  static func pumpMainRunLoop(seconds: TimeInterval = 0.25) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
  }

  func componentState() -> Data? {
    take { v3_get_component_state(handle, $0, $1) }
  }

  func controllerState() -> Data? {
    take { v3_get_controller_state(handle, $0, $1) }
  }

  var parameters: [Parameter] {
    (0..<v3_param_count(handle)).compactMap { i in
      var info = v3_param_info()
      guard v3_param_info_at(handle, i, &info) == 0 else { return nil }
      let title = withUnsafeBytes(of: &info.title) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
      return Parameter(id: info.id, title: title, normalized: info.normalized)
    }
  }

  private func take(_ get: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Int32) -> Data? {
    var ptr: UnsafeMutablePointer<UInt8>?
    var len = 0
    guard get(&ptr, &len) == 0, let ptr else { return nil }
    defer { free(ptr) }
    return Data(bytes: ptr, count: len)
  }
}

enum Vst3Error: Error, CustomStringConvertible {
  case open(String, String)
  case setState(Int32)

  var description: String {
    switch self {
    case .open(let name, let why): return "couldn't open \(name): \(why)"
    case .setState(let r): return "plugin rejected the state (tresult \(r))"
    }
  }
}
