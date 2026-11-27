import AppKit
import SwiftUI

/// One set: whether it opens in a native Live, what fixing it does, and its samples.
struct SetPageView: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel
  @State private var choosingFor: PluginGroup?

  var body: some View {
    let context = app.context(for: model.url)
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        SetHeader(context: context)
        VerdictCard()
        if let entry = context.entry, entry.copyURL != nil {
          CopyCard(set: entry)
        }
        pluginsSection
        SamplesSection(url: model.url)
        if !model.report.isEmpty { reportSection }
      }
      .padding(24)
      .frame(maxWidth: 920, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task { await model.loadIfNeeded() }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        OpenInLiveButton(url: model.url, showsIcon: false)
        Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        .help("Show this set in Finder")
      }
    }
    .sheet(item: $choosingFor) { group in
      ChooseAUView(device: group.devices[0]) { au in
        model.setAction(.replaceAU(au), for: group)
        choosingFor = nil
      } onCancel: {
        choosingFor = nil
      }
    }
  }

  // MARK: Plugins

  @ViewBuilder private var pluginsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("Plugins").font(.headline)
        if !model.groups.isEmpty {
          Text("\(model.groups.count)").foregroundStyle(.secondary)
        }
        Spacer()
        if model.hasChanges {
          Button("Use Recommended") { model.resetChoices() }
            .buttonStyle(.link)
            .help("Undo your choices: fix only what each plugin needs to load")
        }
      }
      if model.document == nil {
        if model.loadError == nil {
          ProgressView().controlSize(.small)
        }
      } else if model.groups.isEmpty {
        Text("No third-party plugins. Everything is Live's own devices.")
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(sortedGroups.enumerated()), id: \.element.id) { i, group in
            if i > 0 { Divider() }
            PluginGroupRow(group: group, choosingFor: $choosingFor)
              .padding(.vertical, 6).padding(.horizontal, 10)
          }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .disabled(catalogs.isHostingPlugins)
      }
      if model.document != nil, model.builtInCount > 0 {
        Text("Also \(model.builtInCount) of Live's own and Max for Live devices, which load as they are.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  /// Won't load first, then what fixing changes, then what already works.
  private var sortedGroups: [PluginGroup] {
    func rank(_ g: PluginGroup) -> Int {
      if !model.willLoad(g) { return 0 }
      return model.action(for: g) == .keep ? 2 : 1
    }
    return model.groups.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
  }

  private var reportSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Notes from the last fix").font(.headline)
      ForEach(Array(model.report.enumerated()), id: \.offset) { _, line in
        Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
  }
}

// MARK: - Header

private struct SetHeader: View {
  @EnvironmentObject var app: AppModel
  let context: SetContext

  var body: some View {
    let url = context.url
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
    if let size = values?.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
    return parts.joined(separator: " · ")
  }

  /// "10.1.40" from "Ableton Live 10.1.40".
  static func version(_ creator: String) -> String? {
    creator.split(separator: " ").last.map(String.init).flatMap { $0.first?.isNumber == true ? $0 : nil }
  }

  /// For sorting: 10.1.40 → 100140.
  static func versionKey(_ creator: String) -> Int {
    let parts = (version(creator) ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    return parts.prefix(3).enumerated().reduce(0) { $0 + $1.element * [10000, 100, 1][$1.offset] }
  }

  static func tempoText(_ tempo: Double) -> String {
    tempo.rounded() == tempo ? "\(Int(tempo)) BPM" : String(format: "%.2f BPM", tempo)
  }

  /// The arrangement's length at the set's tempo.
  static func seconds(_ scan: LiveSetScan) -> Double? {
    guard let beats = scan.arrangementBeats, beats > 0, let tempo = scan.tempo, tempo > 0 else { return nil }
    return beats * 60 / tempo
  }

  static func length(_ scan: LiveSetScan) -> String? { seconds(scan).map(duration) }

  static func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
      : String(format: "%d:%02d", s / 60, s % 60)
  }
}

// MARK: - Verdict

/// Will the set open, and the button that makes it.
private struct VerdictCard: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel

  private struct Verdict {
    var icon: String
    var tint: Color
    var headline: String
    var detail: String
  }

  private var live: String { LiveApps.newestName }

  private var verdict: Verdict {
    if let error = model.loadError {
      return Verdict(icon: "exclamationmark.triangle.fill", tint: .red, headline: "Couldn't read this set", detail: error)
    }
    guard model.document != nil, !catalogs.isLoading else {
      return Verdict(icon: "ellipsis.circle", tint: .secondary, headline: "Checking plugins…",
                     detail: catalogs.isLoading ? "Looking at what's installed." : "Reading the set.")
    }
    let broken = model.brokenGroups
    let changing = model.changingGroups
    let needsResave = model.predatesVst3 && broken.contains { group in
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
        detail: "It was saved by \(model.document?.creator ?? "an older Live"), and sets that old can't hold "
          + "VST3 plugins. Open it in Live 10 or later, save it, then fix it here.")
    }
    if !broken.isEmpty {
      let names = Set(broken.map(\.name)).sorted()
      var detail = names.formatted(.list(type: .and)) + (names.count == 1 ? " has" : " have")
        + " no native version, so \(names.count == 1 ? "it" : "they") won't load."
      if broken.contains(where: { catalogs.substitution(for: $0.devices[0]) != nil }) {
        detail += " A replacement is available below."
      }
      if !changing.isEmpty {
        detail += " Fixing still converts the other \(plural(changing.count, "plugin"))."
      }
      return Verdict(icon: "xmark.octagon.fill", tint: .red, headline: "Won't open fully in \(live)", detail: detail)
    }
    if !changing.isEmpty {
      return Verdict(
        icon: "arrow.right.circle.fill", tint: .blue, headline: "Opens in \(live) once fixed",
        detail: "Fixing converts \(plural(changing.count, "plugin")) and saves the result as a new set "
          + "beside this one. This set isn't changed.")
    }
    var detail = model.groups.isEmpty ? "It only uses Live's own devices." : "Every plugin it uses has a native version."
    let lost = app.lostSamples(of: model.url)
    if lost > 0 { detail += " \(plural(lost, "sample")) can't be found, though: see Samples." }
    return Verdict(icon: "checkmark.circle.fill", tint: .green, headline: "Opens in \(live)", detail: detail)
  }

  var body: some View {
    let v = verdict
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: v.icon).font(.title).foregroundStyle(v.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(v.headline).font(.headline)
        Text(v.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if model.canFix || model.isSaving || model.status != nil {
          HStack(spacing: 10) {
            if model.canFix {
              Button("Fix and Save Copy…") { model.presentSavePanel() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
            }
            if model.isSaving { ProgressView().controlSize(.small) }
            if let status = model.status {
              Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          .padding(.top, 4)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(v.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
          Text(set.copyIsCurrent ? status.detail
               : "Older than this set, so changes saved since aren't in it. Fixing again saves a new copy.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("View") { app.reveal(copy) }
        OpenInLiveButton(url: copy, showsIcon: false)
          .fixedSize()
      }
      .padding(12)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
  }
}

// MARK: - Plugin rows

/// One plugin in the set: what happens to it, and the choice of what to do.
private struct PluginGroupRow: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel
  let group: PluginGroup
  @Binding var choosingFor: PluginGroup?
  @State private var expanded = false

  private struct Outcome {
    var icon: String
    var tint: Color
    var title: String
    var detail: String?
  }

  private var device: Device { group.devices[0] }

  private var outcome: Outcome {
    switch model.action(for: group) {
    case .keep:
      let replacement = catalogs.substitution(for: device).map { "can be replaced with \($0.0.targetName)" }
      switch model.load(of: device) {
      case .native?, nil:
        return Outcome(icon: "checkmark.circle.fill", tint: .green, title: "Works natively")
      case .stuck(let why)?:
        return Outcome(icon: "xmark.octagon.fill", tint: .red, title: "Won't load",
                       detail: [why, replacement].compactMap { $0 }.joined(separator: " · "))
      case .needsConversion?:
        return Outcome(icon: "xmark.octagon.fill", tint: .red, title: "Won't load unless converted",
                       detail: model.predatesVst3 ? "save in Live 10+ first" : "Intel only")
      case .substitute?:
        return Outcome(icon: "xmark.octagon.fill", tint: .red, title: "Won't load",
                       detail: ["Intel only", replacement].compactMap { $0 }.joined(separator: " · "))
      }
    case .replaceVST3(let target):
      let verb = model.loadsNativelyAsVst2(device) ? "Moves to" : "Becomes"
      return Outcome(icon: "arrow.right.circle.fill", tint: .blue, title: "\(verb) \(target.name) VST3",
                     detail: "keeps its settings")
    case .substitute(let sub, _):
      return Outcome(icon: "arrow.triangle.swap", tint: .blue, title: "Replaced with \(sub.targetName)",
                     detail: sub.outcome)
    case .replaceAU(let au):
      return Outcome(icon: "arrow.right.circle.fill", tint: .orange, title: "Becomes \(au.name) AU",
                     detail: "starts from its default settings")
    }
  }

  var body: some View {
    let o = outcome
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(group.devices) { d in
          HStack(spacing: 6) {
            Text(d.trackName)
            if d.name != d.product { Text("› \(d.name)").foregroundStyle(.secondary) }
            if !d.enabled { Text("off").foregroundStyle(.tertiary) }
          }
          .font(.caption)
        }
      }
      .padding(.leading, 30).padding(.top, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: o.icon).foregroundStyle(o.tint).frame(width: 16)
          .accessibilityLabel(o.title)
        if let badge = group.format.badge { FormatBadge(text: badge) }
        Text(group.name).lineLimit(1)
        Text(usage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 1) {
          Text(o.title).lineLimit(1)
          if let detail = o.detail, !detail.isEmpty {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Menu { menuItems } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose what fixing does with \(group.name)")
        .disabled(catalogs.isLoadingAudioUnits)
      }
      .contentShape(Rectangle())
      .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }
  }

  private var usage: String {
    let tracks = group.tracks
    let n = group.devices.count
    return tracks.count == 1 ? (n == 1 ? tracks[0] : "\(n)× on \(tracks[0])")
      : "\(n)× on \(tracks.count) tracks"
  }

  @ViewBuilder private var menuItems: some View {
    let recommended = model.recommendedAction(for: device)
    Button("Leave As Is") { model.setAction(.keep, for: group) }
    switch model.vst3Availability(of: device) {
    case .available(let target):
      Button("\(model.loadsNativelyAsVst2(device) ? "Move" : "Convert") to \(target.name) VST3 (keeps settings)") {
        model.setAction(.replaceVST3(target), for: group)
      }
    case .unavailable(let why):
      Button("VST3: \(why)") {}.disabled(true)
    case nil:
      EmptyView()
    }
    if let sub = Substitution.matching(device) {
      if let (_, target) = catalogs.substitution(for: device) {
        if model.predatesVst3 && !sub.worksBefore10(target) {
          Button("\(sub.targetName): save in Live 10+ first") {}.disabled(true)
        } else {
          Button("Replace with \(sub.targetName) (\(sub.outcome.replacingOccurrences(of: " · ", with: ", ")))") {
            model.setAction(.substitute(sub, target), for: group)
          }
        }
      } else {
        Button("\(sub.targetName): not installed") {}.disabled(true)
      }
    }
    Divider()
    if let au = model.suggestedAU(for: device) {
      Button("Use \(au.name) AU (default settings)") { model.setAction(.replaceAU(au), for: group) }
    }
    Button("Choose Audio Unit… (default settings)") { choosingFor = group }
    if model.action(for: group) != recommended {
      Divider()
      Button("Use Recommended") { model.setAction(recommended, for: group) }
    }
  }
}

// MARK: - Samples

/// Audio files the set refers to that aren't where it expects them.
struct SamplesSection: View {
  @EnvironmentObject var app: AppModel
  let url: URL
  @State private var showingFiles = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Samples").font(.headline)
      if let scan = app.scan(of: url), let missing = app.missingSamples[url] {
        let freeze = missing.filter(\.isFreeze)
        let lost = missing.filter { !$0.isFreeze && !$0.hasNamesake }
        let moved = missing.filter { !$0.isFreeze && $0.hasNamesake }
        if missing.isEmpty {
          Label(scan.samples.isEmpty ? "It doesn't use any samples."
                : "All \(scan.samples.count) samples are where the set expects them.",
                systemImage: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
        } else {
          if !lost.isEmpty {
            Label("\(plural(lost.count, "sample")) can't be found anywhere: not where the set expects, "
                  + "and nothing of the same name is in your libraries or Places.",
                  systemImage: "exclamationmark.triangle.fill")
              .symbolRenderingMode(.multicolor)
          }
          if !moved.isEmpty {
            Label("\(plural(moved.count, "sample")) aren't where the set expects, but files with the same "
                  + "names are in your libraries or Places. Live's File Manager can likely relink them "
                  + "with an automatic search.", systemImage: "arrow.triangle.branch")
          }
          if !freeze.isEmpty {
            Label("\(plural(freeze.count, "freeze file")) missing. Live freezes those tracks again.",
                  systemImage: "snowflake")
              .foregroundStyle(.secondary)
          }
          DisclosureGroup(showingFiles ? "Hide files" : "Show files", isExpanded: $showingFiles) {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(lost + moved + freeze, id: \.self) { sample in
                VStack(alignment: .leading, spacing: 1) {
                  Text(sample.fileName)
                  Text(sample.lastKnown).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                }
                .help(sample.lastKnown)
                .textSelection(.enabled)
              }
            }
            .padding(.top, 4)
          }
          .font(.callout)
        }
      } else {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Looking for its samples…").foregroundStyle(.secondary)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
