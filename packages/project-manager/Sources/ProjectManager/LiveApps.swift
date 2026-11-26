import AppKit
import SwiftUI

/// A Live version, "11.3.43" → 11, 3. Compared by major and minor: within a minor
/// release Live opens any set, but an older minor refuses a newer one's sets.
struct LiveVersion: Comparable, Hashable, Sendable {
  let major: Int
  let minor: Int

  /// "11.3.43", "11.1b6", or a set's creator, "Ableton Live 10.1.40".
  init?(_ text: String) {
    guard let number = text.split(separator: " ").last, number.first?.isNumber == true else { return nil }
    let parts = number.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    major = parts[0]
    minor = parts.count > 1 ? parts[1] : 0
  }

  static func < (a: Self, b: Self) -> Bool { (a.major, a.minor) < (b.major, b.minor) }

  static func major(creator: String) -> Int? { LiveVersion(creator)?.major }

  /// `creator` looks like "Ableton Live 10.1.40".
  static func predatesVst3(creator: String) -> Bool {
    guard let major = major(creator: creator) else { return false }
    return major < 10
  }
}

/// An installed copy of Live.
struct LiveApp: Identifiable, Hashable, Sendable {
  let url: URL
  /// "11.3.43"
  let fullVersion: String
  let version: LiveVersion
  /// Has an Apple Silicon build. An Intel-only Live runs under Rosetta, where it
  /// can load Intel-only plugins too.
  let isNative: Bool
  /// "Live 11", or "Live 11.3" when another installed Live is also 11.
  var name: String

  var id: URL { url }

  /// "11.3.43", or "10.1.43 · Intel (Rosetta)"
  var detail: String { fullVersion + (isNative ? "" : " · Intel (Rosetta)") }
}

/// Installed copies of Live, and which to open a set in.
enum LiveApps {
  /// Oldest first. Looked up once, at launch.
  static let installed: [LiveApp] = find()

  private static func find() -> [LiveApp] {
    var apps: [LiveApp] = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.ableton.live")
      .compactMap { url in
        guard let bundle = Bundle(url: url),
              let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let full = short.split(separator: " ").first.map(String.init),
              let version = LiveVersion(full)
        else { return nil }
        let archs = bundle.executableArchitectures?.map(\.intValue) ?? []
        #if arch(arm64)
        let native = archs.contains(NSBundleExecutableArchitectureARM64)
        #else
        let native = true
        #endif
        return LiveApp(url: url, fullVersion: full, version: version, isNative: native, name: "Live \(version.major)")
      }
    // One app per version: Launch Services can list a copy twice (a backup volume,
    // say); keep the one in /Applications.
    var seen = Set<String>()
    apps = apps.sorted { $0.url.path.hasPrefix("/Applications/") && !$1.url.path.hasPrefix("/Applications/") }
      .filter { seen.insert($0.fullVersion).inserted }
      .sorted { $0.fullVersion.localizedStandardCompare($1.fullVersion) == .orderedAscending }
    for i in apps.indices where apps.filter({ $0.version.major == apps[i].version.major }).count > 1 {
      apps[i].name = "Live \(apps[i].version.major).\(apps[i].version.minor)"
    }
    return apps
  }

  /// The newest Live, whose libraries and plugins the app checks against.
  static var newest: LiveApp? { installed.last }

  /// "Live 11", for text about the newest Live.
  static var newestName: String { newest?.name ?? "Live" }

  /// The Lives that can open a set saved by `creator`, oldest first. An unknown
  /// creator (not scanned yet) could be any version, so every Live is offered.
  static func compatible(withCreator creator: String?) -> [LiveApp] {
    guard let creator, let saved = LiveVersion(creator) else { return installed }
    return installed.filter { $0.version >= saved }
  }

  /// Where a set opens by default: the oldest Live that can open it, so it opens
  /// in the version that saved it and isn't upgraded until you choose a later one.
  /// Unknown sets open in the newest Live, which can open anything the others can.
  static func preferred(forCreator creator: String?) -> LiveApp? {
    guard creator.flatMap(LiveVersion.init) != nil else { return newest }
    return compatible(withCreator: creator).first
  }

  static func open(_ set: URL, in live: LiveApp?) {
    guard let live else {
      NSWorkspace.shared.open(set)
      return
    }
    NSWorkspace.shared.open([set], withApplicationAt: live.url, configuration: NSWorkspace.OpenConfiguration())
  }
}

/// What opening one set offers: a default Live, and the later ones.
@MainActor
struct OpenChoices {
  let url: URL
  /// Who saved the set, when it's been scanned.
  let creator: String?
  let preferred: LiveApp?
  let later: [LiveApp]

  init(url: URL, app: AppModel) {
    self.url = url
    creator = app.scan(of: url)?.creator
    let preferred = LiveApps.preferred(forCreator: creator)
    self.preferred = preferred
    later = LiveApps.compatible(withCreator: creator).filter { $0 != preferred }
  }

  /// No installed Live is new enough.
  var tooNew: Bool { preferred == nil && !LiveApps.installed.isEmpty }

  var title: String {
    if let preferred { return "Open in \(preferred.name)" }
    if tooNew, let creator, let saved = LiveVersion(creator) { return "Needs Live \(saved.major).\(saved.minor)" }
    return "Open"
  }

  var help: String {
    if let preferred {
      let saved = creator.flatMap(SetFacts.version).map { "It was saved by Live \($0). " } ?? ""
      return saved + "Opens in Live \(preferred.detail)" + (later.isEmpty ? "." : "; choose a later Live from the menu.")
    }
    if tooNew, let creator, let newest = LiveApps.newest {
      return "Saved by \(creator), and the newest Live here is \(newest.fullVersion)."
    }
    return "Open this set"
  }

  func open(in live: LiveApp? = nil) { LiveApps.open(url, in: live ?? preferred) }
}

/// Opens a set in its default Live; with later Lives installed, a menu offers them.
struct OpenInLiveButton: View {
  @EnvironmentObject var app: AppModel
  let url: URL
  /// Toolbars show only a label's icon, which wouldn't say which Live.
  var showsIcon = true

  var body: some View {
    let choices = OpenChoices(url: url, app: app)
    Group {
      if choices.later.isEmpty {
        Button { choices.open() } label: { label(choices) }
          .disabled(choices.tooNew)
      } else {
        Menu {
          OpenInLiveItems(choices: choices, includePreferred: false)
        } label: {
          label(choices)
        } primaryAction: {
          choices.open()
        }
        .menuIndicator(.visible)
      }
    }
    .help(choices.help)
  }

  @ViewBuilder private func label(_ choices: OpenChoices) -> some View {
    if showsIcon { Label(choices.title, systemImage: "play.circle") } else { Text(choices.title) }
  }
}

/// Menu items for opening a set: the default first, then each later Live.
struct OpenInLiveItems: View {
  let choices: OpenChoices
  var includePreferred = true

  init(choices: OpenChoices, includePreferred: Bool = true) {
    self.choices = choices
    self.includePreferred = includePreferred
  }

  @MainActor init(url: URL, app: AppModel) {
    self.init(choices: OpenChoices(url: url, app: app))
  }

  var body: some View {
    if includePreferred {
      Button(choices.title) { choices.open() }.disabled(choices.tooNew)
    }
    ForEach(choices.later) { live in
      Button("Open in \(live.name)" + (live.isNative ? "" : " (Rosetta)")) { choices.open(in: live) }
    }
  }
}
