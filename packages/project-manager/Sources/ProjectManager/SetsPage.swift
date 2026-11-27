import AppKit
import SwiftUI

/// The whole library, or one project: how its sets fare, and the sets.
struct SetsPage: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  /// `nil` for the whole library.
  let project: URL?

  private var projectEntry: ProjectEntry? { project.flatMap(app.project) }
  /// The page's title, and the bulk fix's.
  private var title: String { projectEntry?.name ?? app.root?.lastPathComponent ?? "" }

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
      SetsTable(rows: rows, spansProjects: projectEntry == nil)
    }
    // Keyed by project: moving between projects reuses this view.
    .task(id: project) { if let projectEntry { app.measure(projectEntry) } }
  }

  @ViewBuilder private func header(sets: [LiveSetEntry]) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.weight(.semibold))
        Text(subtitle(sets: sets)).foregroundStyle(.secondary)
      }
      Spacer()
      if let url = projectEntry?.url ?? app.root {
        Button("Open Folder") { NSWorkspace.shared.open(url) }
          .help("Open this folder in Finder")
      }
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
    let holding = app.plugins.filter { $0.verdict.holdsBack && $0.sets.contains(where: urls.contains) }
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
              app.presentBatch(for: sets, title: title)
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
      SetsTable(rows: rows, spansProjects: true)
    }
  }
}
