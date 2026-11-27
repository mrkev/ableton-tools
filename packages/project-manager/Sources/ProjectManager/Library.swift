import Foundation

/// One Live Set in a project folder.
struct LiveSetEntry: Identifiable, Hashable, Codable {
  let url: URL
  /// A fixed copy saved beside it (`<name>-vst3.als`, or `-converted.als`).
  var copyURL: URL?
  /// The copy is at least as new as this set, so it still reflects it.
  var copyIsCurrent = false
  /// When the set was last saved.
  var modified: Date?
  /// The file's size in bytes.
  var size: Int64?

  init(url: URL, copyURL: URL? = nil, copyIsCurrent: Bool = false, modified: Date? = nil, size: Int64? = nil) {
    self.url = url
    self.copyURL = copyURL
    self.copyIsCurrent = copyIsCurrent
    self.modified = modified
    self.size = size
  }

  /// The copy, when it's current.
  var convertedURL: URL? { copyIsCurrent ? copyURL : nil }
  var id: URL { url }
  var name: String { url.deletingPathExtension().lastPathComponent }
}

/// A project folder and the sets directly inside it.
struct ProjectEntry: Identifiable, Hashable {
  let url: URL
  let sets: [LiveSetEntry]
  /// When the folder was made. Live rewrites a set's file on every save, so this is
  /// the only creation date that lasts.
  var created: Date?

  var id: URL { url }
  /// Live names project folders "<name> Project".
  var name: String {
    let folder = url.lastPathComponent
    return folder.hasSuffix(" Project") ? String(folder.dropLast(" Project".count)) : folder
  }
}

enum LibraryDiscovery {
  static let convertedSuffix = "-vst3"
  /// Names a fixed copy can have, preferred first. `-converted` is what Save As
  /// suggests when a device became an AU.
  static let copySuffixes = [convertedSuffix, "-converted"]
  private static let projectMarker = "Ableton Project Info"
  private static let keys: Set<URLResourceKey> = [
    .isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey,
  ]

  /// The projects in a folder: the folder itself when it's a project, or else the
  /// project folders inside it. Empty when there are none.
  static func projects(in folder: URL) -> [ProjectEntry] {
    guard isDirectory(folder) else { return [] }
    if !isDirectory(folder.appendingPathComponent(projectMarker)) {
      let inside = subfolders(of: folder).compactMap(project(at:))
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      if !inside.isEmpty { return inside }
    }
    return [project(at: folder)].compactMap { $0 }
  }

  /// Sets sit directly in the project folder, so `Backup` is skipped naturally.
  private static func project(at url: URL) -> ProjectEntry? {
    let files = contents(of: url).filter { $0.pathExtension == "als" }
    let names = Set(files.map { $0.deletingPathExtension().lastPathComponent })
    let sets = files.compactMap { file -> LiveSetEntry? in
      let name = file.deletingPathExtension().lastPathComponent
      // A copy belongs to its original, not the list of sets.
      if copySuffixes.contains(where: { name.hasSuffix($0) && names.contains(String(name.dropLast($0.count))) }) {
        return nil
      }
      let copy = copySuffixes.lazy.map { url.appendingPathComponent(name + $0 + ".als") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
      let values = try? file.resourceValues(forKeys: keys)
      return LiveSetEntry(
        url: file, copyURL: copy, copyIsCurrent: copy.map { isCurrent($0, for: file) } ?? false,
        modified: values?.contentModificationDate, size: values?.fileSize.map(Int64.init))
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    guard !sets.isEmpty else { return nil }
    return ProjectEntry(url: url, sets: sets, created: try? url.resourceValues(forKeys: keys).creationDate)
  }

  /// A conversion older than its original no longer reflects it.
  private static func isCurrent(_ converted: URL, for original: URL) -> Bool {
    guard let new = modified(converted), let old = modified(original) else { return false }
    return new >= old
  }

  private static func modified(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private static func contents(of url: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
  }

  private static func subfolders(of url: URL) -> [URL] { contents(of: url).filter(isDirectory) }
}

/// Whether a set will open with all its plugins in a native (Apple Silicon) Live.
enum SetStatus: Hashable {
  case scanning
  case failed(String)
  /// Every plugin has a native build. `convertible` VST2 devices could still move
  /// to VST3, but don't need to.
  case opens(convertible: Int)
  /// Opens once these devices are converted (VST2 to VST3, or an opted-in
  /// substitution).
  case afterConverting(Int)
  /// Saved by Live < 10, so `Int` devices can only convert after a re-save. A set
  /// that needs no conversion just opens: Live upgrades it.
  case resaveFirst(Int)
  /// These plugins have nothing native. `convertible` other devices could convert,
  /// but the set still wouldn't open fully.
  case stuck([StuckPlugin], convertible: Int)
  /// `<name>-vst3.als` is current and opens.
  case converted

  /// The one rule for a set's status.
  static func resolve(
    scan: LiveSetScan, convertedScan: LiveSetScan?, hasConversion: Bool, inventory: PluginInventory
  ) -> SetStatus {
    if hasConversion {
      guard let convertedScan else { return .scanning }
      // A conversion made before opting in to a substitution still has the plugin.
      let stuck = inventory.loads(in: convertedScan).compactMap { name, load -> StuckPlugin? in
        switch load {
        case .stuck(let reason): return StuckPlugin(name: name, reason: reason)
        case .substitute, .needsConversion:
          return StuckPlugin(name: name, reason: "the -vst3.als predates this replacement; remove it to convert again")
        case .native: return nil
        }
      }
      return stuck.isEmpty ? .converted : .stuck(stuck, convertible: 0)
    }
    let convertible = scan.predatesVst3
      ? inventory.loads(in: scan).filter { $0.load.needsWork && !$0.load.needsLive10 }.count
      : inventory.convertibleCount(in: scan)
    let stuck = inventory.stuckPlugins(in: scan)
    if !stuck.isEmpty { return .stuck(stuck, convertible: convertible) }
    let work = inventory.loads(in: scan).map(\.load).filter(\.needsWork)
    if !work.isEmpty {
      return scan.predatesVst3 && work.contains(where: \.needsLive10) ? .resaveFirst(work.count) : .afterConverting(work.count)
    }
    return .opens(convertible: convertible)
  }

  var kind: Kind {
    switch self {
    case .scanning: return .scanning
    case .failed: return .failed
    case .opens: return .opens
    case .afterConverting: return .afterConverting
    case .resaveFirst: return .resaveFirst
    case .stuck: return .stuck
    case .converted: return .converted
    }
  }

  /// A short description for a sidebar row.
  var detail: String {
    switch self {
    case .scanning: return "Scanning…"
    case .failed(let why): return "Couldn't read: \(why)"
    case .opens(let n):
      return n == 0 ? "Opens natively" : "Opens natively; \(n) VST2 could still move to VST3"
    case .afterConverting(let n): return "Opens after converting \(n) device\(n == 1 ? "" : "s")"
    case .resaveFirst(let n): return "Re-save in Live 10+, then convert \(n) device\(n == 1 ? "" : "s")"
    case .stuck(let plugins, _):
      return "Stuck on " + Set(plugins.map(\.name)).sorted().joined(separator: ", ")
    case .converted: return "Converted, and opens natively"
    }
  }

  /// Most urgent first; a project shows its first non-empty kind.
  enum Kind: Int, CaseIterable, Comparable {
    case afterConverting, resaveFirst, stuck, failed, scanning, converted, opens

    static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

    var needsWork: Bool { [.afterConverting, .resaveFirst, .stuck, .failed].contains(self) }

    var title: String {
      switch self {
      case .afterConverting: return "Opens after converting"
      case .resaveFirst: return "Re-save, then convert"
      case .stuck: return "Stuck on plugins"
      case .failed: return "Couldn't read"
      case .scanning: return "Scanning"
      case .converted: return "Converted"
      case .opens: return "Opens natively"
      }
    }

    var explanation: String {
      switch self {
      case .afterConverting: return "Needs VST2 devices replaced by their native VST3s, or opted-in replacements."
      case .resaveFirst: return "Saved by Live 9. Re-save in Live 10+, then convert."
      case .stuck: return "Uses a plugin with no native build Live can use."
      case .failed: return "The file couldn't be read as a Live Set."
      case .scanning: return "Not checked yet."
      case .converted: return "A current -vst3.als exists beside the set and opens natively."
      case .opens: return "Every plugin has a native build. Nothing to do."
      }
    }

    var icon: String {
      switch self {
      case .afterConverting: return "arrow.right.circle.fill"
      case .resaveFirst: return "arrow.triangle.2.circlepath"
      case .stuck: return "nosign"
      case .failed: return "exclamationmark.triangle.fill"
      case .scanning: return "ellipsis.circle"
      case .converted: return "checkmark.circle.fill"
      case .opens: return "checkmark.circle"
      }
    }
  }
}
