import Foundation

/// One Live Set in a project folder.
struct LiveSetEntry: Identifiable, Hashable, Codable {
  let url: URL
  /// `<name>-vst3.als`, when it exists and is at least as new as this set.
  let convertedURL: URL?

  var id: URL { url }
  var name: String { url.deletingPathExtension().lastPathComponent }
}

/// A project folder and the sets directly inside it.
struct ProjectEntry: Identifiable, Hashable {
  let url: URL
  let sets: [LiveSetEntry]

  var id: URL { url }
  /// Live names project folders "<name> Project".
  var name: String {
    let folder = url.lastPathComponent
    return folder.hasSuffix(" Project") ? String(folder.dropLast(" Project".count)) : folder
  }
}

/// What the user opened.
enum OpenedRoot: Equatable {
  case library(URL)
  case project(URL)
  case set(URL)

  var url: URL {
    switch self {
    case .library(let u), .project(let u), .set(let u): return u
    }
  }
}

enum LibraryDiscovery {
  static let convertedSuffix = "-vst3"
  private static let projectMarker = "Ableton Project Info"

  /// A single set, a project folder, or a folder of project folders.
  static func classify(_ url: URL) -> OpenedRoot? {
    guard isDirectory(url) else { return url.pathExtension == "als" ? .set(url) : nil }
    if isMarkedProject(url) { return .project(url) }
    if subfolders(of: url).contains(where: { isMarkedProject($0) || !setFiles(in: $0).isEmpty }) {
      return .library(url)
    }
    return setFiles(in: url).isEmpty ? nil : .project(url)
  }

  static func projects(for root: OpenedRoot) -> [ProjectEntry] {
    switch root {
    case .set:
      return []
    case .project(let url):
      return [project(at: url)].compactMap { $0 }
    case .library(let url):
      return subfolders(of: url).compactMap(project(at:))
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
  }

  /// Sets sit directly in the project folder, so `Backup` is skipped naturally.
  private static func project(at url: URL) -> ProjectEntry? {
    let files = setFiles(in: url)
    let names = Set(files.map { $0.deletingPathExtension().lastPathComponent })
    let sets = files.compactMap { file -> LiveSetEntry? in
      let name = file.deletingPathExtension().lastPathComponent
      // A conversion belongs to its original, not the list of work to do.
      if name.hasSuffix(convertedSuffix), names.contains(String(name.dropLast(convertedSuffix.count))) {
        return nil
      }
      let converted = url.appendingPathComponent(name + convertedSuffix + ".als")
      return LiveSetEntry(url: file, convertedURL: isCurrent(converted, for: file) ? converted : nil)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return sets.isEmpty ? nil : ProjectEntry(url: url, sets: sets)
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

  private static func isMarkedProject(_ url: URL) -> Bool {
    isDirectory(url.appendingPathComponent(projectMarker))
  }

  private static func contents(of url: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])) ?? []
  }

  private static func subfolders(of url: URL) -> [URL] { contents(of: url).filter(isDirectory) }

  private static func setFiles(in url: URL) -> [URL] {
    contents(of: url).filter { $0.pathExtension == "als" }
  }
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
    let convertible = scan.predatesVst3 ? 0 : inventory.convertibleCount(in: scan)
    let stuck = inventory.stuckPlugins(in: scan)
    if !stuck.isEmpty { return .stuck(stuck, convertible: convertible) }
    let needed = inventory.loads(in: scan).filter(\.load.needsWork).count
    if needed > 0 { return scan.predatesVst3 ? .resaveFirst(needed) : .afterConverting(needed) }
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
