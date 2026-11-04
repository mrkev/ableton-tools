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

/// Where a set stands in the VST2 → VST3 migration.
enum SetStatus: Hashable {
  case scanning
  case failed(String)
  /// No VST2 devices.
  case clean
  /// Every VST2 device can convert.
  case ready(Int)
  case partial(convertible: Int, blocked: Int)
  case blocked(Int)
  /// Saved by Live < 10; re-saving comes before anything else.
  case needsResave(Int)
  /// `<name>-vst3.als` is current, with this many VST2 devices left in it.
  case converted(remaining: Int)

  /// The one rule for a set's status, given its scan and the installed VST3s.
  static func resolve(
    scan: LiveSetScan, convertedScan: LiveSetScan?, hasConversion: Bool,
    catalog: [Vst3PluginInfo], catalogLoading: Bool
  ) -> SetStatus {
    if hasConversion { return .converted(remaining: convertedScan?.vst2.count ?? 0) }
    if scan.vst2.isEmpty { return .clean }
    if scan.predatesVst3 { return .needsResave(scan.vst2.count) }
    if catalogLoading { return .scanning }
    let convertible = scan.vst2.filter {
      if case .available = Vst3Availability.resolve($0, catalog: catalog) { return true }
      return false
    }.count
    if convertible == scan.vst2.count { return .ready(convertible) }
    if convertible == 0 { return .blocked(scan.vst2.count) }
    return .partial(convertible: convertible, blocked: scan.vst2.count - convertible)
  }

  var kind: Kind {
    switch self {
    case .scanning: return .scanning
    case .failed: return .failed
    case .clean: return .clean
    case .ready: return .ready
    case .partial: return .partial
    case .blocked: return .blocked
    case .needsResave: return .needsResave
    case .converted: return .converted
    }
  }

  /// A short description for a sidebar row.
  var detail: String {
    switch self {
    case .scanning: return "Scanning…"
    case .failed(let why): return "Couldn't read: \(why)"
    case .clean: return "No VST2 devices"
    case .ready(let n): return "\(n) VST2 ready to convert"
    case .partial(let ok, let no): return "\(ok) VST2 ready, \(no) can't convert"
    case .blocked(let n): return "\(n) VST2 can't convert"
    case .needsResave(let n): return "\(n) VST2, re-save in Live 10+ first"
    case .converted(let left): return left == 0 ? "Converted" : "Converted, \(left) VST2 left"
    }
  }

  /// Most urgent first; a project shows its first non-empty kind.
  enum Kind: Int, CaseIterable, Comparable {
    case ready, partial, blocked, needsResave, failed, scanning, converted, clean

    static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

    var needsWork: Bool { [.ready, .partial, .blocked, .needsResave, .failed].contains(self) }

    var title: String {
      switch self {
      case .ready: return "Ready to convert"
      case .partial: return "Partly convertible"
      case .blocked: return "Blocked"
      case .needsResave: return "Needs re-saving"
      case .failed: return "Couldn't read"
      case .scanning: return "Scanning"
      case .converted: return "Converted"
      case .clean: return "Nothing to do"
      }
    }

    var explanation: String {
      switch self {
      case .ready: return "Every VST2 device has a native VST3."
      case .partial: return "Some VST2 devices have no usable VST3 yet."
      case .blocked: return "None of the VST2 devices have a usable VST3 yet."
      case .needsResave: return "Saved by Live 9. Open and re-save in Live 10+ to convert."
      case .failed: return "The file couldn't be read as a Live Set."
      case .scanning: return "Not checked yet."
      case .converted: return "A current -vst3.als exists beside the set."
      case .clean: return "No VST2 devices in the set."
      }
    }

    var icon: String {
      switch self {
      case .ready: return "arrow.right.circle.fill"
      case .partial: return "circle.lefthalf.filled"
      case .blocked: return "nosign"
      case .needsResave: return "arrow.triangle.2.circlepath"
      case .failed: return "exclamationmark.triangle.fill"
      case .scanning: return "ellipsis.circle"
      case .converted: return "checkmark.circle.fill"
      case .clean: return "minus.circle"
      }
    }
  }
}
