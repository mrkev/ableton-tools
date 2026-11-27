import AppKit
import SwiftUI

/// A set's row in a table, with everything sortable.
struct SetTableRow: Identifiable {
  let id: URL
  let name: String
  let project: String
  let status: SetStatus
  /// Shown as the set's Kind.
  let architecture: SetArchitecture?
  let version: String
  let versionKey: Int
  let tempo: Double
  let seconds: Double
  let tracks: Int
  /// Third-party plugins, once per format and name.
  let plugins: Int
  let samples: Int
  let lostSamples: Int
  let copy: FixedCopy
  let size: Int64
  let projectCreated: Date
  let modified: Date

  var statusRank: Int { status.kind.rawValue }
  var architectureRank: Int { architecture?.rawValue ?? -1 }

  /// A scan lists every device; count each plugin once per format.
  private static func pluginCount(_ scan: LiveSetScan) -> Int {
    let vst2: [String] = scan.vst2.map { "VST2 " + $0.name }
    let vst3: [String] = scan.vst3.map { "VST3 " + $0.name }
    let au: [String] = scan.au.map { "AU " + $0.name }
    return Set(vst2 + vst3 + au).count
  }

  @MainActor init(set: LiveSetEntry, project: ProjectEntry, app: AppModel) {
    let scan = app.scan(of: set.url)
    id = set.url
    name = set.name
    self.project = project.name
    status = app.status(of: set)
    architecture = app.architecture(of: set.url)
    version = scan.flatMap { SetFacts.version($0.creator) } ?? ""
    versionKey = scan.map { SetFacts.versionKey($0.creator) } ?? 0
    tempo = scan?.tempo ?? 0
    seconds = scan.flatMap(SetFacts.seconds) ?? 0
    tracks = scan?.tracks ?? 0
    plugins = scan.map(Self.pluginCount) ?? 0
    samples = scan?.samples.count ?? 0
    lostSamples = app.lostSamples(of: set.url)
    copy = set.copyURL == nil ? .none : set.copyIsCurrent ? .current : .outOfDate
    size = set.size ?? 0
    projectCreated = project.created ?? .distantPast
    modified = set.modified ?? .distantPast
  }
}

/// Whether a set has a fixed copy beside it. Sorts by how much the copy is worth.
enum FixedCopy: Int, Comparable {
  case none, outOfDate, current

  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Sets with their status and vital statistics. Double-click opens a set's page;
/// right-click the header to show or hide columns.
struct SetsTable: View {
  @EnvironmentObject var app: AppModel
  let rows: [SetTableRow]
  /// Whether the rows span projects, so the Project column is worth showing.
  let spansProjects: Bool
  /// Which columns are shown, and how wide, remembered separately for tables
  /// that span projects and those that don't.
  @StoredColumns<SetTableRow> private var columns: TableColumnCustomization<SetTableRow>
  @State private var sortOrder = [KeyPathComparator(\SetTableRow.modified, order: .reverse)]
  @State private var selection = Set<URL>()

  init(rows: [SetTableRow], spansProjects: Bool) {
    self.rows = rows
    self.spansProjects = spansProjects
    _columns = StoredColumns(spansProjects ? "libraryTableColumns.2" : "projectTableColumns.2")
  }

  var body: some View {
    Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      identity
      music
      files
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

  typealias Columns = TableColumnBuilder<SetTableRow, KeyPathComparator<SetTableRow>>

  /// Which set, and how it fares.
  @Columns private var identity: some TableColumnContent<SetTableRow, KeyPathComparator<SetTableRow>> {
    TableColumn("Set Name", value: \.name) { row in Text(row.name).lineLimit(1) }
      .width(min: 100, ideal: 170)
      .customizationID("set")
      .disabledCustomizationBehavior(.visibility)
    TableColumn("Project", value: \.project) { row in
      Text(row.project).foregroundStyle(.secondary).lineLimit(1)
    }
    .width(min: 70, ideal: 130)
    .customizationID("project")
    .defaultVisibility(spansProjects ? .automatic : .hidden)
    TableColumn("Status", value: \.statusRank) { row in
      HStack(spacing: 6) {
        StatusIcon(kind: row.status.kind)
        Text(row.status.kind.title).lineLimit(1)
      }
      .help(row.status.detail)
    }
    .width(min: 110, ideal: 170)
    .customizationID("status")
    TableColumn("Kind", value: \.architectureRank) { row in
      // Only Native and x86-64 sets load anywhere.
      Text(row.architecture?.title ?? "")
        .foregroundStyle(row.architecture.map { $0 > .x86_64 } == true ? .red : .primary)
        .help(row.architecture?.explanation ?? "")
    }
    .width(min: 50, ideal: 96)
    .customizationID("kind")
  }

  /// What's in it.
  @Columns private var music: some TableColumnContent<SetTableRow, KeyPathComparator<SetTableRow>> {
    TableColumn("Live Version", value: \.versionKey) { row in Text(row.version).monospacedDigit() }
      .width(min: 90, ideal: 92)
      .customizationID("live")
    TableColumn("Tempo", value: \.tempo) { row in
      Text(row.tempo > 0 ? SetFacts.tempoText(row.tempo).replacingOccurrences(of: " BPM", with: "") : "")
        .monospacedDigit()
    }
    .width(min: 54, ideal: 58, max: 90)
    .customizationID("tempo")
    .defaultVisibility(.hidden)
    TableColumn("Length", value: \.seconds) { row in
      Text(row.seconds > 0 ? SetFacts.duration(row.seconds) : "").monospacedDigit()
    }
    .width(min: 58, ideal: 62, max: 90)
    .customizationID("length")
    TableColumn("Tracks", value: \.tracks) { row in Text("\(row.tracks)").monospacedDigit() }
      .width(min: 56, ideal: 58, max: 90)
      .customizationID("tracks")
    TableColumn("Plugins", value: \.plugins) { row in Text("\(row.plugins)").monospacedDigit() }
      .width(min: 60, ideal: 62, max: 90)
      .customizationID("plugins")
  }

  /// Its files.
  @Columns private var files: some TableColumnContent<SetTableRow, KeyPathComparator<SetTableRow>> {
    TableColumn("Samples", value: \.samples) { row in Text("\(row.samples)").monospacedDigit() }
      .width(min: 66, ideal: 68, max: 100)
      .customizationID("samples")
      .defaultVisibility(.hidden)
    TableColumn("Missing Samples", value: \.lostSamples) { row in
      if row.lostSamples > 0 {
        Text("\(row.lostSamples)").monospacedDigit().foregroundStyle(.orange)
          .help("\(plural(row.lostSamples, "sample")) can't be found")
      }
    }
    .width(min: 112, ideal: 114, max: 160)
    .customizationID("missing")
    TableColumn("Fixed Copy", value: \.copy) { row in
      switch row.copy {
      case .current: Text("Current")
      case .outOfDate: Text("Out of date").foregroundStyle(.orange)
      case .none: EmptyView()
      }
    }
    .width(min: 80, ideal: 90)
    .customizationID("copy")
    .defaultVisibility(.hidden)
    TableColumn("Size", value: \.size) { row in
      Text(row.size > 0 ? ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file) : "")
        .monospacedDigit()
    }
    .width(min: 50, ideal: 70)
    .customizationID("size")
    .defaultVisibility(.hidden)
    TableColumn("Project Created", value: \.projectCreated) { row in Text(SetsTable.date(row.projectCreated)) }
      .width(min: 112, ideal: 160)
      .customizationID("created")
    TableColumn("Modified", value: \.modified) { row in Text(SetsTable.date(row.modified)) }
      .width(min: 92, ideal: 160)
      .customizationID("modified")
  }

  /// As Finder writes it: "Today at 3:30 pm", "23 Nov 2026 at 3:05 pm".
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return f
  }()

  private static func date(_ date: Date) -> String {
    date == .distantPast ? "" : dateFormatter.string(from: date)
  }
}
