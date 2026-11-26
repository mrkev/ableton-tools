import AppKit
import SwiftUI

// MARK: - Sets table

/// A set's row in a table, with everything sortable.
struct SetTableRow: Identifiable {
  let id: URL
  let name: String
  let project: String
  let status: SetStatus
  let version: String
  let versionKey: Int
  let tempo: Double
  let seconds: Double
  let tracks: Int
  let lostSamples: Int
  let modified: Date

  var statusRank: Int { status.kind.rawValue }

  @MainActor init(set: LiveSetEntry, project: ProjectEntry, app: AppModel) {
    let scan = app.scan(of: set.url)
    id = set.url
    name = set.name
    self.project = project.name
    status = app.status(of: set)
    version = scan.flatMap { SetFacts.version($0.creator) } ?? ""
    versionKey = scan.map { SetFacts.versionKey($0.creator) } ?? 0
    tempo = scan?.tempo ?? 0
    seconds = scan.flatMap(SetFacts.seconds) ?? 0
    tracks = scan?.tracks ?? 0
    lostSamples = app.lostSamples(of: set.url)
    modified = set.modified ?? .distantPast
  }
}

/// Sets with their status and vital statistics. Double-click opens a set's page.
struct SetsTable: View {
  @EnvironmentObject var app: AppModel
  let rows: [SetTableRow]
  var showsProject = true
  @State private var sortOrder = [KeyPathComparator(\SetTableRow.modified, order: .reverse)]
  @State private var selection = Set<URL>()

  var body: some View {
    Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
      TableColumn("Set", value: \.name) { row in
        VStack(alignment: .leading, spacing: 1) {
          Text(row.name).lineLimit(1)
          if showsProject && row.project != row.name {
            Text(row.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      .width(min: 160, ideal: 240)
      TableColumn("Status", value: \.statusRank) { row in
        HStack(spacing: 6) {
          StatusIcon(kind: row.status.kind)
          Text(row.status.kind.title).lineLimit(1)
        }
        .help(row.status.detail)
      }
      .width(min: 120, ideal: 170)
      TableColumn("Live", value: \.versionKey) { row in Text(row.version).monospacedDigit() }
        .width(min: 50, ideal: 70)
      TableColumn("Tempo", value: \.tempo) { row in
        Text(row.tempo > 0 ? SetFacts.tempoText(row.tempo).replacingOccurrences(of: " BPM", with: "") : "")
          .monospacedDigit()
      }
      .width(min: 44, ideal: 56)
      TableColumn("Length", value: \.seconds) { row in
        Text(row.seconds > 0 ? SetFacts.duration(row.seconds) : "").monospacedDigit()
      }
      .width(min: 44, ideal: 60)
      TableColumn("Tracks", value: \.tracks) { row in Text("\(row.tracks)").monospacedDigit() }
        .width(min: 40, ideal: 50)
      TableColumn("Missing", value: \.lostSamples) { row in
        if row.lostSamples > 0 {
          Text("\(row.lostSamples)").monospacedDigit().foregroundStyle(.orange)
            .help("\(plural(row.lostSamples, "sample")) can't be found")
        }
      }
      .width(min: 44, ideal: 56)
      TableColumn("Saved", value: \.modified) { row in
        Text(row.modified == .distantPast ? "" : row.modified.formatted(date: .abbreviated, time: .omitted))
      }
      .width(min: 80, ideal: 100)
    }
    .contextMenu(forSelectionType: URL.self) { urls in
      if urls.count == 1, let url = urls.first {
        Button("Show Set") { app.reveal(url) }
        OpenInLiveItems(url: url, app: app)
        Divider()
      }
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
      if urls.count > 1 {
        Button("Fix \(urls.count) Sets…") {
          app.presentBatch(for: app.allSets.filter { urls.contains($0.url) }, title: "\(urls.count) sets")
        }
      }
    } primaryAction: { urls in
      if let url = urls.first { app.reveal(url) }
    }
  }
}

// MARK: - Library and project pages

/// The whole library, or one project: how its sets fare, and the sets.
struct SetsPage: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  /// `nil` for the whole library.
  let project: URL?

  private var projectEntry: ProjectEntry? {
    if let project { return app.projects.first { $0.url == project } }
    if case .project = app.root { return app.projects.first }
    return nil
  }

  var body: some View {
    let scope = projectEntry.map { [$0] } ?? app.projects
    let sets = scope.flatMap(\.sets)
    let rows = scope.flatMap { p in p.sets.filter { app.matchesSearch($0, in: p) }.map { SetTableRow(set: $0, project: p, app: app) } }
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
        header(sets: sets)
        StatusSummary(sets: sets)
        attention(sets: sets)
      }
      .padding(24)
      SetsTable(rows: rows, showsProject: projectEntry == nil)
    }
    .onAppear { if let projectEntry { app.measure(projectEntry) } }
    .toolbar {
      if let url = projectEntry?.url ?? app.root?.url {
        ToolbarItem(placement: .primaryAction) {
          Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label("Show in Finder", systemImage: "folder")
          }
          .help("Show this folder in Finder")
        }
      }
    }
  }

  @ViewBuilder private func header(sets: [LiveSetEntry]) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text(projectEntry?.name ?? app.root?.url.lastPathComponent ?? "").font(.title2.weight(.semibold))
        Text(subtitle(sets: sets)).foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private func subtitle(sets: [LiveSetEntry]) -> String {
    var parts = [plural(sets.count, "set")]
    if let projectEntry {
      if let size = app.projectSizes[projectEntry.url] {
        parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
      }
      parts.append(projectEntry.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    } else {
      parts.insert(plural(app.projects.count, "project"), at: 0)
    }
    if app.isSearching { parts.append("matching “\(app.searchText)”") }
    return parts.joined(separator: " · ")
  }

  /// Names once each, in order (a plugin can be in a library as VST2 and AU).
  static func unique(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.filter { seen.insert($0.lowercased()).inserted }
  }

  /// What's worth doing next here.
  @ViewBuilder private func attention(sets: [LiveSetEntry]) -> some View {
    let urls = Set(sets.map(\.url))
    let holding = app.plugins.filter { $0.verdict.rank < 2 && $0.sets.contains(where: urls.contains) }
      .sorted { $0.sets.filter(urls.contains).count > $1.sets.filter(urls.contains).count }
    let missing = sets.filter { app.lostSamples(of: $0.url) > 0 }.count
    let fixable = app.batchCandidates(in: sets)
    if !holding.isEmpty || missing > 0 || !fixable.required.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        if !holding.isEmpty {
          HStack(spacing: 4) {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary).frame(width: 18)
            Text("Held back most by " + Self.unique(holding.map(\.name)).prefix(3).formatted(.list(type: .and)) + ".")
            Button("See plugins") { app.selection = [.plugins] }.buttonStyle(.link)
          }
        }
        if missing > 0 {
          Label("\(plural(missing, "set")) can't find some of their samples.",
                systemImage: "waveform.badge.exclamationmark")
        }
        if !fixable.required.isEmpty {
          HStack(spacing: 4) {
            Image(systemName: "arrow.right.circle").foregroundStyle(.secondary).frame(width: 18)
            Text("\(plural(fixable.required.count, "set")) open once fixed.")
            Button("Fix several at once…") {
              app.presentBatch(for: sets, title: projectEntry?.name ?? app.root?.url.lastPathComponent ?? "")
            }
            .buttonStyle(.link)
            .disabled(app.isScanning || catalogs.isLoading)
          }
        }
      }
      .font(.callout)
    }
  }
}

/// Counts of sets by status, in a row.
struct StatusSummary: View {
  @EnvironmentObject var app: AppModel
  let sets: [LiveSetEntry]

  var body: some View {
    let counts = app.counts(in: sets)
    FlowLayout(spacing: 18, lineSpacing: 6) {
      ForEach(SetStatus.Kind.allCases.filter { counts[$0] != nil }, id: \.self) { kind in
        HStack(spacing: 5) {
          StatusIcon(kind: kind)
          Text("\(counts[kind] ?? 0)").monospacedDigit().fontWeight(.medium)
          Text(kind.title).foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(kind.explanation)
      }
    }
    .font(.callout)
  }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for i in row.indices {
        let size = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows = [Row()]
    for i in subviews.indices {
      let size = subviews[i].sizeThatFits(.unspecified)
      let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      if rows[rows.count - 1].width + extra > width && !rows[rows.count - 1].indices.isEmpty {
        rows.append(Row())
      }
      let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      rows[rows.count - 1].indices.append(i)
      rows[rows.count - 1].width += added
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
    }
    return rows.filter { !$0.indices.isEmpty }
  }
}

/// Several sets picked in the sidebar.
struct SelectionPage: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs

  var body: some View {
    let sets = app.selectedSets
    let rows = app.projects.flatMap { p in
      p.sets.filter { set in sets.contains { $0.url == set.url } }.map { SetTableRow(set: $0, project: p, app: app) }
    }
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
        Text("\(plural(sets.count, "set")) selected").font(.title2.weight(.semibold))
        StatusSummary(sets: sets)
        let candidates = app.batchCandidates(in: sets)
        HStack {
          Button("Fix \(plural(sets.count, "Set"))…") { app.presentBatch(for: sets, title: "\(sets.count) selected sets") }
            .buttonStyle(.borderedProminent)
            .disabled(candidates.isEmpty || app.isScanning || catalogs.isLoading)
          if candidates.isEmpty {
            Text("None of these has anything to fix.").foregroundStyle(.secondary)
          }
        }
      }
      .padding(24)
      SetsTable(rows: rows)
    }
  }
}

// MARK: - Plugins

/// Every plugin in the library: what it needs, and which sets use it.
struct PluginsPage: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @State private var filter = Filter.all
  @State private var sortOrder = [KeyPathComparator(\PluginUsage.setCount, order: .reverse)]
  @State private var selection: PluginUsage.ID?

  enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case attention = "Needs attention"
    case native = "Works natively"
    var id: String { rawValue }
  }

  private var rows: [PluginUsage] {
    let query = app.searchText.trimmingCharacters(in: .whitespaces)
    return app.plugins.filter { p in
      switch filter {
      case .all: true
      case .attention: p.verdict.rank < 3
      case .native: p.verdict == .native
      }
    }
    .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    .sorted(using: sortOrder)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Plugins").font(.title2.weight(.semibold))
          Text(summary).foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Show", selection: $filter) {
          ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      .padding(24)

      if catalogs.isLoading || (app.plugins.isEmpty && app.isScanning) {
        ProgressView("Looking at installed plugins…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
          TableColumn("Plugin", value: \.name) { p in
            HStack(spacing: 6) {
              FormatBadge(text: p.formatName)
              Text(p.name).lineLimit(1)
            }
          }
          .width(min: 140, ideal: 190)
          TableColumn("Status", value: \.verdictRank) { p in
            HStack(spacing: 6) {
              Image(systemName: p.verdict.icon).foregroundStyle(p.verdict.tint).frame(width: 16)
              Text(p.verdict.title).lineLimit(1)
              if let detail = p.verdict.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            .help([p.verdict.title, p.verdict.detail].compactMap { $0 }.joined(separator: ": "))
          }
          .width(min: 160, ideal: 280)
          TableColumn("Sets", value: \.setCount) { p in Text("\(p.setCount)").monospacedDigit() }
            .width(min: 40, ideal: 50)
          TableColumn("Uses", value: \.instances) { p in
            Text("\(p.instances)").monospacedDigit().foregroundStyle(.secondary)
          }
          .width(min: 40, ideal: 50)
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
          if let usage = app.plugins.first(where: { $0.id == selection }) {
            PluginInspector(usage: usage)
              .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
          }
        }
      }
    }
  }

  private var summary: String {
    let stuck = app.plugins.filter { if case .stuck = $0.verdict { true } else { false } }.count
    return "\(plural(app.plugins.count, "plugin")) across the library"
      + (stuck > 0 ? " · \(stuck) with no native version" : "")
  }
}

extension PluginVerdict {
  var icon: String {
    switch self {
    case .native: return "checkmark.circle.fill"
    case .converts: return "arrow.right.circle.fill"
    case .replaceable: return "arrow.triangle.swap"
    case .stuck: return "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch self {
    case .native: return .green
    case .converts: return .blue
    case .replaceable: return .orange
    case .stuck: return .red
    }
  }
}

/// One plugin: what to do about it, and the sets that use it.
private struct PluginInspector: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  let usage: PluginUsage

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            FormatBadge(text: usage.formatName)
            Text(usage.name).font(.title3.weight(.semibold))
          }
          Label(usage.verdict.title, systemImage: usage.verdict.icon)
            .foregroundStyle(usage.verdict.tint)
          if let detail = usage.verdict.detail {
            Text(detail).font(.callout).foregroundStyle(.secondary)
          }
        }
        if case .replaceable(let s) = usage.verdict {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Replace when fixing a set", isOn: catalogs.isOptedIn(s))
              .toggleStyle(.checkbox)
            Text(s.explanation).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Text("Used \(usage.instances == 1 ? "once" : "\(usage.instances) times") in \(plural(usage.setCount, "set"))")
          .font(.headline)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(usage.sets, id: \.self) { url in
            let context = app.context(for: url)
            Button { app.reveal(url) } label: {
              HStack(spacing: 6) {
                StatusIcon(kind: app.status(of: url).kind)
                VStack(alignment: .leading, spacing: 0) {
                  Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                  if let project = context.project, project.name != url.deletingPathExtension().lastPathComponent {
                    Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
