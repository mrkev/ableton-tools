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

  var predatesVst3: Bool { LiveVersion.predatesVst3(creator: creator) }
}

enum LiveVersion {
  /// 10 for "Ableton Live 10.1.40".
  static func major(creator: String) -> Int? {
    creator.split(separator: " ").last?.split(separator: ".").first.flatMap { Int($0) }
  }

  /// VST3 support (and the block layout we write) arrived in Live 10.
  /// `creator` looks like "Ableton Live 10.1.40".
  static func predatesVst3(creator: String) -> Bool {
    guard let major = major(creator: creator) else { return false }
    return major < 10
  }
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
      return LiveSetScan(creator: creator ?? "", vst2: plugins, vst3: vst3, au: au)
    }
  }

  private struct Bytes {
    let start: UnsafeRawPointer
    let count: Int

    func find(_ needle: String, from: Int, before limit: Int? = nil) -> Int? {
      let end = limit ?? count
      guard from < end else { return nil }
      return needle.withCString { n in
        memmem(start + from, end - from, n, strlen(n)).map { UnsafeRawPointer($0) - start }
      }
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
    .appendingPathComponent("DeviceConverter/live-set-scans-v3.json")

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
