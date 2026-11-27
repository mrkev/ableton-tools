import AppKit
import SwiftUI

/// One set: whether it opens in a native Live, and tabs for its plugins and samples.
struct SetPageView: View {
  @EnvironmentObject var app: AppModel
  
  @EnvironmentObject var model: SetModel
  /// Kept across sets, so browsing samples stays on Samples.
  @AppStorage("setPageTab") private var tab = SetPageTab.plugins

  enum SetPageTab: String {
    case plugins, samples
  }

  var body: some View {
    let context = app.context(for: model.url)
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        SetHeader(context: context)
        VerdictBanner()
        if let entry = context.entry, entry.copyURL != nil {
          CopyCard(set: entry)
        }
      }
      .padding([.horizontal, .top], 24)
      .padding(.bottom, 14)
      // Sized first: the tabs take what's left. Not fixedSize: SwiftUI also
      // measures it at narrow widths, where it wraps tall, and that height
      // becomes the window's minimum, which outgrows the window.
      .layoutPriority(1)

      TabView(selection: $tab) {
        Tab(value: SetPageTab.plugins) {
          SetPluginsTab()
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity)
        } label: {
          Text(pluginsTitle)
        }
        Tab(value: SetPageTab.samples) {
          SetSamplesTab(url: model.url)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity)
        } label: {
          Text(samplesTitle)
        }
      }
      .tabViewStyle(.grouped)
      .padding([.horizontal, .bottom], 24)

      // Holds the header at the top until the tabs fill the rest.
      Spacer(minLength: 0)
    }
    .task { await model.loadIfNeeded() }
  }

  private var pluginsTitle: String {
    model.document == nil ? "Plugins" : "Plugins (\(model.groups.count))"
  }

  private var samplesTitle: String {
    guard let scan = app.scan(of: model.url) else { return "Samples" }
    let lost = app.lostSamples(of: model.url)
    return "Samples (\(scan.samples.count))" + (lost > 0 ? " · \(lost) missing" : "")
  }
}

// MARK: - Header

/// The set's name and facts, and what to do with its file.
private struct SetHeader: View {
  @EnvironmentObject var app: AppModel
  let context: SetContext

  var body: some View {
    let url = context.url
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text(url.deletingPathExtension().lastPathComponent)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
        if let original = context.original {
          HStack(spacing: 4) {
            Text("Fixed copy of")
            Button(original.name) { app.reveal(original.url) }.buttonStyle(.link)
          }
          .font(.callout)
        }
        Text(SetFacts.line(scan: app.scan(of: url), url: url, project: context.project))
          .font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      HStack {
        OpenInLiveButton(url: url)
          .fixedSize()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    }
  }
}

/// A set's vital statistics, in one line.
enum SetFacts {
  static func line(scan: LiveSetScan?, url: URL, project: ProjectEntry?) -> String {
    var parts: [String] = []
    if let project, project.name != url.deletingPathExtension().lastPathComponent {
      parts.append(project.name)
    }
    if let scan {
      if let version = version(scan.creator) { parts.append("Live \(version)") }
      if let tempo = scan.tempo { parts.append(tempoText(tempo)) }
      if let length = length(scan) { parts.append(length) }
      parts.append("\(scan.tracks) track\(scan.tracks == 1 ? "" : "s")")
    }
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    if let date = values?.contentModificationDate {
      parts.append("saved " + date.formatted(date: .abbreviated, time: .omitted))
    }
    if let size = values?.fileSize {
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
    }
    return parts.joined(separator: " · ")
  }

  /// "10.1.40" from "Ableton Live 10.1.40".
  static func version(_ creator: String) -> String? {
    creator.split(separator: " ").last.map(String.init).flatMap {
      $0.first?.isNumber == true ? $0 : nil
    }
  }

  /// For sorting: 10.1.40 → 100140.
  static func versionKey(_ creator: String) -> Int {
    let parts = (version(creator) ?? "").split(separator: ".").map {
      Int($0.prefix { $0.isNumber }) ?? 0
    }
    return parts.prefix(3).enumerated().reduce(0) { $0 + $1.element * [10000, 100, 1][$1.offset] }
  }

  static func tempoText(_ tempo: Double) -> String {
    tempo.rounded() == tempo ? "\(Int(tempo)) BPM" : String(format: "%.2f BPM", tempo)
  }

  /// The arrangement's length at the set's tempo.
  static func seconds(_ scan: LiveSetScan) -> Double? {
    guard let beats = scan.arrangementBeats, beats > 0, let tempo = scan.tempo, tempo > 0 else {
      return nil
    }
    return beats * 60 / tempo
  }

  static func length(_ scan: LiveSetScan) -> String? { seconds(scan).map(duration) }

  static func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600
      ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
      : String(format: "%d:%02d", s / 60, s % 60)
  }
}

// MARK: - Verdict

/// Will the set open natively, and the button that makes it. Left out when
/// there's nothing to say: the set opens natively in the Live that saved it.
private struct VerdictBanner: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel

  private struct Verdict {
    var icon: String
    var tint: Color
    var headline: String
    var detail: String
    /// Opens natively, and was saved by the newest Live's major version.
    var isRoutine = false
  }

  private var live: String { LiveApps.newestName }

  private var verdict: Verdict {
    if let error = model.loadError {
      return Verdict(
        icon: "exclamationmark.triangle.fill", tint: .red, headline: "Couldn't read this set",
        detail: error)
    }
    guard model.document != nil, !catalogs.isLoading else {
      return Verdict(
        icon: "ellipsis.circle", tint: .secondary, headline: "Checking plugins…",
        detail: catalogs.isLoading ? "Looking at what's installed." : "Reading the set.")
    }
    let broken = model.brokenGroups
    let changing = model.changingGroups
    let needsResave =
      model.predatesVst3
      && broken.contains { group in
        switch model.load(of: group.devices[0]) {
        case .needsConversion?: return true
        case .substitute(let s, let target)?: return !s.worksBefore10(target)
        default: return false
        }
      }
    if needsResave {
      return Verdict(
        icon: "arrow.triangle.2.circlepath", tint: .orange,
        headline: "Save it in Live 10 or later first",
        detail:
          "It was saved by \(model.document?.creator ?? "an older Live"), and sets that old can't hold "
          + "VST3 plugins. Open it in Live 10 or later, save it, then fix it here.")
    }
    if !broken.isEmpty {
      let names = Set(broken.map(\.name)).sorted()
      var detail =
        names.formatted(.list(type: .and)) + (names.count == 1 ? " has" : " have")
        + " no native version, so \(names.count == 1 ? "it" : "they") won't load."
      if broken.contains(where: { catalogs.substitution(for: $0.devices[0]) != nil }) {
        detail += " A replacement is available below."
      }
      if !changing.isEmpty {
        detail += " Fixing still converts the other \(plural(changing.count, "plugin"))."
      }
      return Verdict(
        icon: "xmark.octagon.fill", tint: .red, headline: "Won't open natively in \(live)",
        detail: detail)
    }
    if !changing.isEmpty {
      return Verdict(
        icon: "arrow.right.circle.fill", tint: .blue,
        headline: "Opens natively in \(live) once fixed",
        detail:
          "Fixing converts \(plural(changing.count, "plugin")) and saves the result as a new set "
          + "beside this one. This set isn't changed.")
    }
    var detail =
      model.groups.isEmpty
      ? "It only uses Live's own devices." : "Every plugin it uses has a native version."
    let lost = app.lostSamples(of: model.url)
    if lost > 0 { detail += " \(plural(lost, "sample")) can't be found, though: see Samples." }
    let saved = model.document.flatMap { LiveVersion($0.creator) }
    return Verdict(
      icon: "checkmark.circle.fill", tint: .green, headline: "Opens natively in \(live)",
      detail: detail,
      isRoutine: saved != nil && saved?.major == LiveApps.newest?.version.major)
  }

  var body: some View {
    let v = verdict
    let acting = model.canFix || model.isSaving || model.status != nil
    if !v.isRoutine || acting {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Image(systemName: v.icon).foregroundStyle(v.tint)
            .accessibilityHidden(true)
          (Text(v.headline).fontWeight(.semibold) + Text("  ")
            + Text(v.detail).foregroundStyle(.secondary))
          Spacer(minLength: 8)
          if model.isSaving { ProgressView().controlSize(.small) }
          if model.canFix {
            Button("Fix and Save Copy…") { model.presentSavePanel() }
              .buttonStyle(.borderedProminent)
              .keyboardShortcut("s")
          }
        }
        if let status = model.status {
          Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .padding(.leading, 24)
        }
      }
      .font(.callout)
      .padding(.horizontal, 10).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(v.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
  }
}

func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

// MARK: - Fixed copy

private struct CopyCard: View {
  @EnvironmentObject var app: AppModel
  let set: LiveSetEntry

  var body: some View {
    if let copy = set.copyURL {
      let status = app.copyStatus(of: set) ?? .scanning
      HStack(spacing: 12) {
        Image(systemName: set.copyIsCurrent ? "doc.on.doc" : "clock.badge.exclamationmark")
          .font(.title3).foregroundStyle(set.copyIsCurrent ? Color.secondary : .orange)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
          Text("Fixed copy: \(copy.lastPathComponent)")
          Text(
            set.copyIsCurrent
              ? status.detail
              : "Older than this set, so changes saved since aren't in it. Fixing again saves a new copy."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("View") { app.reveal(copy) }
        OpenInLiveButton(url: copy)
          .fixedSize()
      }
      .padding(12)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
  }
}
