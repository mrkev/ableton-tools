import Foundation

/// What the library needs to know about a set, without building its DOM.
struct LiveSetScan: Codable, Sendable, Equatable {
  struct Vst2Plugin: Codable, Sendable, Hashable {
    let name: String
    let uniqueId: Int32?
    /// Holds a chunk (`FBCh`) preset, the only kind that converts to VST3.
    let isChunk: Bool
  }

  let creator: String
  let vst2: [Vst2Plugin]
  let vst3Count: Int
  let auCount: Int

  var predatesVst3: Bool { LiveVersion.predatesVst3(creator: creator) }
}

enum LiveVersion {
  /// VST3 support (and the block layout we write) arrived in Live 10.
  /// `creator` looks like "Ableton Live 10.1.40".
  static func predatesVst3(creator: String) -> Bool {
    guard let major = creator.split(separator: " ").last?.split(separator: ".").first
      .flatMap({ Int($0) }) else { return false }
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
      let creator = doc.attribute("Creator=\"", from: root, before: doc.find(">", from: root) ?? root)

      var plugins: [LiveSetScan.Vst2Plugin] = []
      var cursor = 0
      while let start = doc.find("<VstPluginInfo", from: cursor) {
        let end = doc.find("</VstPluginInfo>", from: start) ?? raw.count
        // `Dir` has a `Type` of its own, so look for the preset's after `VstPreset`.
        let preset = doc.find("<VstPreset", from: start, before: end)
        let type = preset.flatMap { doc.attribute("<Type Value=\"", from: $0, before: end) }
        plugins.append(LiveSetScan.Vst2Plugin(
          name: doc.attribute("<PlugName Value=\"", from: start, before: end) ?? "VST Plugin",
          uniqueId: doc.attribute("<UniqueId Value=\"", from: start, before: end).flatMap { Int32($0) },
          isChunk: type.flatMap { Int($0) }.flatMap(DeviceExtractor.fourCC) == "FBCh"))
        cursor = end
      }
      return LiveSetScan(
        creator: creator ?? "", vst2: plugins,
        vst3Count: doc.count("<Vst3PluginInfo"), auCount: doc.count("<AuPluginInfo"))
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

    /// The text from just after `prefix` up to the closing quote, XML-unescaped.
    func attribute(_ prefix: String, from: Int, before limit: Int) -> String? {
      guard limit > from, let hit = find(prefix, from: from, before: limit) else { return nil }
      let valueStart = hit + prefix.utf8.count
      guard let close = find("\"", from: valueStart, before: limit) else { return nil }
      let bytes = UnsafeRawBufferPointer(start: start + valueStart, count: close - valueStart)
      return String(decoding: bytes, as: UTF8.self).xmlUnescaped
    }

    func count(_ needle: String) -> Int {
      var n = 0, cursor = 0
      while let hit = find(needle, from: cursor) {
        n += 1
        cursor = hit + needle.utf8.count
      }
      return n
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
    .appendingPathComponent("DeviceConverter/live-set-scans-v1.json")

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
