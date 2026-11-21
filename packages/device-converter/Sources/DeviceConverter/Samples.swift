import AppKit
import Foundation

/// An audio file a set refers to, as the set records it.
struct SampleRef: Codable, Sendable, Hashable {
  /// Live's `RelativePathType`: 1 relative to the set's folder (outside the
  /// project), 3 inside the project, 5 Live's Core Library or a pack, 6 the
  /// User Library.
  let kind: Int
  /// Relative to whatever `kind` says, with `..` to step up.
  let relative: String
  let absolute: String?
  /// The pack it came from (Live 10.1+ records this).
  let pack: String?

  var fileName: String {
    let name = (relative as NSString).lastPathComponent
    return name.isEmpty ? ((absolute ?? "") as NSString).lastPathComponent : name
  }

  /// Audio of a frozen track: Live freezes the track again if it's missing.
  var isFreeze: Bool { relative.contains("Samples/Processed/Freeze/") }
}

/// A sample no candidate location has.
struct MissingSample: Hashable, Sendable {
  let fileName: String
  /// Where the set last had it.
  let lastKnown: String
  let isFreeze: Bool
  /// A file with its name is in Live's libraries or your Places, so Live's File
  /// Manager ("Search Library") can likely relink it.
  let hasNamesake: Bool
}

/// Where Live keeps its libraries, read from the newest Live's preferences.
struct LiveLocations: Sendable {
  var coreLibrary: URL?
  var userLibrary: URL?
  /// Installed packs by name.
  var packs: [String: URL] = [:]
  var factoryPacks: URL?
  /// Folders added to the browser's Places.
  var places: [URL] = []

  static func current() -> LiveLocations {
    var out = LiveLocations()
    if let live = LiveApps.newest() {
      out.coreLibrary = live.url.appendingPathComponent("Contents/App-Resources/Core Library")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let prefs = home.appendingPathComponent("Library/Preferences/Ableton")
    let folders = (try? FileManager.default.contentsOfDirectory(at: prefs, includingPropertiesForKeys: nil)) ?? []
    let newest = folders.filter { $0.lastPathComponent.hasPrefix("Live ") }
      .max { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    if let cfg = newest.flatMap({ try? XMLDocument(contentsOf: $0.appendingPathComponent("Library.cfg")) }) {
      if let path = (try? cfg.nodes(forXPath: "//UserLibrary//ProjectPath/@Value"))?.first?.stringValue {
        out.userLibrary = URL(fileURLWithPath: path).appendingPathComponent("User Library")
      }
      for node in (try? cfg.nodes(forXPath: "//LibrarySliceInfo")) ?? [] {
        guard let element = node as? XMLElement, let path = element.attribute(forName: "Path")?.stringValue,
              let name = element.attribute(forName: "DisplayName")?.stringValue else { continue }
        out.packs[name] = URL(fileURLWithPath: path)
      }
      for node in (try? cfg.nodes(forXPath: "//UserFolderInfo/@Path")) ?? [] {
        if let path = node.stringValue { out.places.append(URL(fileURLWithPath: path)) }
      }
    }
    let music = home.appendingPathComponent("Music/Ableton")
    out.userLibrary = out.userLibrary ?? music.appendingPathComponent("User Library")
    out.factoryPacks = out.packs.values.first?.deletingLastPathComponent() ?? music.appendingPathComponent("Factory Packs")
    return out
  }

  /// Places Live would look for a sample, most likely first.
  func candidates(for sample: SampleRef, setFolder: URL) -> [String] {
    var out: [String] = []
    func relative(to base: URL?) {
      guard let base, !sample.relative.isEmpty else { return }
      out.append(base.appendingPathComponent(sample.relative).standardizedFileURL.path)
    }
    if let absolute = sample.absolute { out.append(absolute) }
    switch sample.kind {
    case 1, 3: relative(to: setFolder)
    case 5:
      if let pack = sample.pack, pack != "Core Library" { relative(to: packs[pack]) } else { relative(to: coreLibrary) }
    case 6: relative(to: userLibrary)
    default: break
    }
    if sample.relative.hasPrefix("~/") { out.append((sample.relative as NSString).expandingTildeInPath) }
    // A library path from another Live version (or another Mac) maps onto this one's.
    if let absolute = sample.absolute {
      if let range = absolute.range(of: "/Core Library/"), let coreLibrary {
        out.append(coreLibrary.appendingPathComponent(String(absolute[range.upperBound...])).path)
      }
      if let range = absolute.range(of: "/Factory Packs/"), let factoryPacks {
        out.append(factoryPacks.appendingPathComponent(String(absolute[range.upperBound...])).path)
      }
      if let range = absolute.range(of: "/User Library/"), let userLibrary {
        out.append(userLibrary.appendingPathComponent(String(absolute[range.upperBound...])).path)
      }
    }
    return out
  }

  /// The set's samples that aren't anywhere Live would look. Touches the disk.
  func missing(in scan: LiveSetScan, setURL: URL, index: SampleIndex) -> [MissingSample] {
    let folder = setURL.deletingLastPathComponent()
    let fm = FileManager.default
    return scan.samples.compactMap { sample in
      let places = candidates(for: sample, setFolder: folder)
      if places.contains(where: { fm.fileExists(atPath: $0) }) { return nil }
      return MissingSample(
        fileName: sample.fileName, lastKnown: places.first ?? sample.relative, isFreeze: sample.isFreeze,
        hasNamesake: index.contains(sample.fileName))
    }
  }

  /// Every folder Live's browser searches.
  var searchRoots: [URL] {
    [coreLibrary, userLibrary, factoryPacks].compactMap { $0 } + Array(packs.values) + places
  }
}

/// File names of the audio in Live's libraries and Places, to tell a moved sample
/// from a lost one. Builds in well under a second for tens of thousands of files.
struct SampleIndex: Sendable {
  private var names = Set<String>()

  static let empty = SampleIndex()

  static func build(_ locations: LiveLocations) -> SampleIndex {
    var out = SampleIndex()
    let audio: Set<String> = ["wav", "aif", "aiff", "mp3", "flac", "m4a", "ogg", "caf"]
    var visited = Set<String>()
    for root in locations.searchRoots where visited.insert(root.standardizedFileURL.path).inserted {
      guard let e = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      for case let url as URL in e where audio.contains(url.pathExtension.lowercased()) {
        out.names.insert(url.lastPathComponent.lowercased())
      }
    }
    return out
  }

  func contains(_ fileName: String) -> Bool { names.contains(fileName.lowercased()) }
}

/// The POSIX path inside a classic Mac alias record, which Live 9 and 10.0 store
/// as hex. After the 150-byte header come tagged fields: 0x12 is the path from
/// the volume's root, 0x13 the volume's mount point.
enum AliasRecord {
  static func path(hex: String) -> String? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.utf8.count / 2)
    var high: UInt8?
    for c in hex.utf8 {
      let v: UInt8
      switch c {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
      case UInt8(ascii: "A")...UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
      case UInt8(ascii: "a")...UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
      default: continue
      }
      if let h = high {
        bytes.append(h << 4 | v)
        high = nil
      } else {
        high = v
      }
    }
    var path: String?, mount: String?
    var i = 150
    while i + 4 <= bytes.count {
      let tag = Int16(bitPattern: UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
      let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
      if tag == -1 || i + 4 + length > bytes.count { break }
      let value = String(decoding: bytes[(i + 4)..<(i + 4 + length)], as: UTF8.self)
      if tag == 0x12 { path = value }
      if tag == 0x13 { mount = value }
      i += 4 + length + (length & 1)
    }
    guard let path else { return nil }
    let root = (mount == nil || mount == "/") ? "" : mount!
    return root + (path.hasPrefix("/") ? path : "/" + path)
  }
}

/// Installed copies of Live.
enum LiveApps {
  struct App {
    let url: URL
    let version: String
    /// "Live 11"
    var name: String { "Live " + (version.split(separator: ".").first.map(String.init) ?? version) }
  }

  static func installed() -> [App] {
    NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.ableton.live").compactMap { url in
      guard let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      else { return nil }
      return App(url: url, version: String(version.split(separator: " ").first ?? ""))
    }
  }

  /// The newest Live, which is the one to open sets in.
  static func newest() -> App? {
    installed().max { $0.version.localizedStandardCompare($1.version) == .orderedAscending }
  }

  /// "Live 11", for buttons. Looked up once.
  @MainActor static let newestName = newest()?.name ?? "Live"

  static func open(_ set: URL) {
    guard let live = newest() else {
      NSWorkspace.shared.open(set)
      return
    }
    NSWorkspace.shared.open([set], withApplicationAt: live.url, configuration: NSWorkspace.OpenConfiguration())
  }
}
