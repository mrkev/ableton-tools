import Foundation

/// What the library needs to know about a set, without building its DOM.
struct LiveSetScan: Codable, Sendable, Equatable {
  struct Vst2Plugin: Codable, Sendable, Hashable {
    let name: String
    let uniqueId: Int32?
    /// Holds a chunk (`FBCh`) preset.
    let isChunk: Bool
    /// Holds Live's dump of the plugin's parameter values (`FxBk`).
    var isParameterDump = false
    /// The bundle Live loaded it from, e.g. "Serum.vst".
    var fileName: String?
  }

  struct Vst3Plugin: Codable, Sendable, Hashable {
    let name: String
    let uid: [Int32]
  }

  struct AuPlugin: Codable, Sendable, Hashable {
    let name: String
    let type: Int32
    let subType: Int32
    let manufacturer: Int32
  }

  let creator: String
  let vst2: [Vst2Plugin]
  let vst3: [Vst3Plugin]
  let au: [AuPlugin]
  /// The song tempo (its value at the start, when automated).
  var tempo: Double?
  /// Audio and MIDI tracks.
  var tracks = 0
  /// Where the last arrangement clip ends, in beats.
  var arrangementBeats: Double?
  /// Every audio file the set refers to, once each.
  var samples: [SampleRef] = []

  var predatesVst3: Bool { LiveVersion.predatesVst3(creator: creator) }
}

/// Reads plugin facts straight from a set's decompressed bytes. Building a DOM
/// for hundreds of sets is too slow and memory-hungry just to fill a sidebar;
/// `--selftest-library` checks this agrees with `DeviceExtractor`.
enum LiveSetScanner {
  static func scan(url: URL) throws -> LiveSetScan {
    let xml = try Gzip.inflate(Data(contentsOf: url))
    return try xml.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.baseAddress else { throw AlsError.notALiveSet }
      let doc = Bytes(start: base, count: raw.count)
      guard let root = doc.find("<Ableton", from: 0) else { throw AlsError.notALiveSet }
      let creator = doc.attribute("Creator=", from: root, before: doc.find(">", from: root) ?? root)

      var plugins: [LiveSetScan.Vst2Plugin] = []
      var cursor = 0
      while let start = doc.find("<VstPluginInfo", from: cursor) {
        let end = doc.find("</VstPluginInfo>", from: start) ?? raw.count
        // `Dir` has a `Type` of its own, so look for the preset's after `VstPreset`.
        let preset = doc.find("<VstPreset", from: start, before: end)
        let type = preset.flatMap { doc.attribute("<Type Value=", from: $0, before: end) }
        plugins.append(LiveSetScan.Vst2Plugin(
          name: doc.attribute("<PlugName Value=", from: start, before: end) ?? "VST Plugin",
          uniqueId: doc.attribute("<UniqueId Value=", from: start, before: end).flatMap { Int32($0) },
          isChunk: type.flatMap { Int($0) }.flatMap(DeviceExtractor.fourCC) == "FBCh",
          isParameterDump: type.flatMap { Int($0) }.flatMap(DeviceExtractor.fourCC) == "FxBk",
          fileName: doc.attribute("<FileName Value=", from: start, before: end)))
        cursor = end
      }

      // The identity of these sits outside their `Preset`, which has its own `Name`.
      var vst3: [LiveSetScan.Vst3Plugin] = []
      cursor = 0
      while let start = doc.find("<Vst3PluginInfo", from: cursor) {
        let end = doc.find("</Vst3PluginInfo>", from: start) ?? raw.count
        let identity = doc.find("</Preset>", from: start, before: end) ?? start
        vst3.append(LiveSetScan.Vst3Plugin(
          name: doc.attribute("<Name Value=", from: identity, before: end) ?? "VST3 Plugin",
          uid: (0..<4).compactMap { i in
            doc.attribute("<Fields.\(i) Value=", from: identity, before: end).flatMap { Int32($0) }
          }))
        cursor = end
      }

      var au: [LiveSetScan.AuPlugin] = []
      cursor = 0
      while let start = doc.find("<AuPluginInfo", from: cursor) {
        let end = doc.find("</AuPluginInfo>", from: start) ?? raw.count
        let limit = doc.find("<Preset", from: start, before: end) ?? end
        func code(_ tag: String) -> Int32 {
          doc.attribute("<\(tag) Value=", from: start, before: limit).flatMap { Int32($0) } ?? 0
        }
        au.append(LiveSetScan.AuPlugin(
          name: doc.attribute("<Name Value=", from: start, before: limit) ?? "AU Plugin",
          type: code("ComponentType"), subType: code("ComponentSubType"),
          manufacturer: code("ComponentManufacturer")))
        cursor = end
      }
      var out = LiveSetScan(creator: creator ?? "", vst2: plugins, vst3: vst3, au: au)
      out.tempo = tempo(doc)
      out.tracks = doc.count("<AudioTrack Id=") + doc.count("<MidiTrack Id=")
      out.arrangementBeats = arrangementEnd(doc)
      out.samples = sampleRefs(doc)
      return out
    }
  }

  /// The master track's tempo: its `Manual` value, or (Live 8) the first event of
  /// its automation.
  private static func tempo(_ doc: Bytes) -> Double? {
    guard let master = doc.find("<MasterTrack", from: 0),
          let start = doc.find("<Tempo>", from: master) else { return nil }
    let end = doc.find("</Tempo>", from: start) ?? doc.count
    if let manual = doc.attribute("<Manual Value=", from: start, before: end) { return Double(manual) }
    guard let event = doc.find("<FloatEvent", from: start, before: end) else { return nil }
    return doc.attribute(" Value=", from: event, before: end).flatMap(Double.init)
  }

  /// Arrangement clips sit in `ArrangerAutomation` lists, which elsewhere only hold
  /// automation events; a clip's `CurrentEnd` is where it ends in the arrangement.
  private static func arrangementEnd(_ doc: Bytes) -> Double? {
    var latest: Double?
    var cursor = 0
    while let start = doc.find("<ArrangerAutomation>", from: cursor) {
      let end = doc.find("</ArrangerAutomation>", from: start) ?? doc.count
      var at = start
      while let hit = doc.find("<CurrentEnd Value=", from: at, before: end) {
        if let value = doc.attribute("<CurrentEnd Value=", from: hit, before: end).flatMap(Double.init) {
          latest = max(latest ?? value, value)
        }
        at = hit + 1
      }
      cursor = end
    }
    return latest
  }

  /// The file of each `SampleRef`. Live 10.1+ writes `RelativePath` and `Path` as
  /// values; earlier versions write the relative path as elements and the
  /// absolute one inside a Mac alias record (`Data`).
  private static func sampleRefs(_ doc: Bytes) -> [SampleRef] {
    var seen = Set<SampleRef>()
    var out: [SampleRef] = []
    var cursor = 0
    while let ref = doc.find("<SampleRef>", from: cursor) {
      cursor = ref + 1
      guard let start = doc.find("<FileRef", from: ref),
            let end = doc.find("</FileRef>", from: start) else { break }
      cursor = end
      let kind = doc.attribute("<RelativePathType Value=", from: start, before: end).flatMap { Int($0) } ?? 0
      var sample: SampleRef
      if let relative = doc.attribute("<RelativePath Value=", from: start, before: end) {
        sample = SampleRef(
          kind: kind, relative: relative,
          absolute: doc.attribute("<Path Value=", from: start, before: end),
          pack: doc.attribute("<LivePackName Value=", from: start, before: end))
      } else {
        var dirs: [String] = []
        var after = start
        if let open = doc.find("<RelativePath>", from: start, before: end),
           let close = doc.find("</RelativePath>", from: open, before: end) {
          var at = open
          while let hit = doc.find("Dir=", from: at, before: close) {
            dirs.append(doc.attribute("Dir=", from: hit, before: close) ?? "")
            at = hit + 1
          }
          after = close
        }
        let name = doc.attribute("<Name Value=", from: after, before: end) ?? ""
        var absolute: String?
        if let open = doc.find("<Data>", from: after, before: end),
           let close = doc.find("</Data>", from: open, before: end) {
          absolute = AliasRecord.path(hex: doc.text(from: open + 6, to: close))
        }
        // An empty `Dir` steps up a folder.
        let relative = (dirs.map { $0.isEmpty ? ".." : $0 } + [name]).joined(separator: "/")
        sample = SampleRef(kind: kind, relative: relative, absolute: absolute, pack: nil)
      }
      if seen.insert(sample).inserted { out.append(sample) }
    }
    return out
  }

  fileprivate struct Bytes {
    let start: UnsafeRawPointer
    let count: Int

    func find(_ needle: String, from: Int, before limit: Int? = nil) -> Int? {
      let end = limit ?? count
      guard from < end else { return nil }
      return needle.withCString { n in
        memmem(start + from, end - from, n, strlen(n)).map { UnsafeRawPointer($0) - start }
      }
    }

    func count(_ needle: String) -> Int {
      var n = 0, at = 0
      while let hit = find(needle, from: at) {
        n += 1
        at = hit + 1
      }
      return n
    }

    func text(from: Int, to end: Int) -> String {
      String(decoding: UnsafeRawBufferPointer(start: start + from, count: max(0, end - from)), as: UTF8.self)
    }

    /// The quoted text just after `prefix` (e.g. `<Name Value=`), XML-unescaped.
    /// Live writes double quotes, but attributes created through XMLDocument can
    /// come out single-quoted.
    func attribute(_ prefix: String, from: Int, before limit: Int) -> String? {
      guard limit > from, let hit = find(prefix, from: from, before: limit) else { return nil }
      let quoteAt = hit + prefix.utf8.count
      guard quoteAt < limit else { return nil }
      let quote = start.load(fromByteOffset: quoteAt, as: UInt8.self)
      guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { return nil }
      let valueStart = quoteAt + 1
      guard let close = find(quote == UInt8(ascii: "\"") ? "\"" : "'", from: valueStart, before: limit) else {
        return nil
      }
      let bytes = UnsafeRawBufferPointer(start: start + valueStart, count: close - valueStart)
      return String(decoding: bytes, as: UTF8.self).xmlUnescaped
    }
  }
}

private extension String {
  var xmlUnescaped: String {
    guard contains("&") else { return self }
    return replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }
}

/// Scan results on disk, keyed by path and invalidated by date and size, so
/// reopening a library doesn't decompress every set again.
struct LiveSetScanCache {
  private struct Entry: Codable {
    let modified: Double
    let size: Int
    let scan: LiveSetScan
  }

  private var entries: [String: Entry] = [:]

  /// Bump when `LiveSetScan`'s meaning changes.
  private static let fileURL = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ProjectManager/live-set-scans-v4.json")

  static func load() -> LiveSetScanCache {
    var cache = LiveSetScanCache()
    if let data = try? Data(contentsOf: fileURL),
       let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
      cache.entries = entries
    }
    return cache
  }

  func save() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? FileManager.default.createDirectory(
      at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: Self.fileURL, options: .atomic)
  }

  func lookup(_ url: URL) -> LiveSetScan? {
    guard let entry = entries[url.path], let stamp = Self.stamp(url),
          entry.modified == stamp.modified, entry.size == stamp.size else { return nil }
    return entry.scan
  }

  mutating func store(_ scan: LiveSetScan, for url: URL) {
    guard let stamp = Self.stamp(url) else { return }
    entries[url.path] = Entry(modified: stamp.modified, size: stamp.size, scan: scan)
  }

  private static func stamp(_ url: URL) -> (modified: Double, size: Int)? {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    guard let date = values?.contentModificationDate, let size = values?.fileSize else { return nil }
    return (date.timeIntervalSince1970, size)
  }
}

extension LiveSetScan.AuPlugin {
  /// `nil` for anything that isn't an AU device.
  init?(device: Device) {
    guard device.format == .au,
          let info = device.element.firstChild("PluginDesc")?.firstChild("AuPluginInfo") else { return nil }
    func code(_ tag: String) -> Int32 { info.childValue(tag).flatMap { Int32($0) } ?? 0 }
    self.init(
      name: info.childValue("Name") ?? device.product, type: code("ComponentType"),
      subType: code("ComponentSubType"), manufacturer: code("ComponentManufacturer"))
  }
}
