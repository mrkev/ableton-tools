import AppKit
import SwiftUI

/// A set page's Samples tab: what's missing, then every sample and where it is.
struct SetSamplesTab: View {
  @EnvironmentObject var app: AppModel
  let url: URL
  @State private var sortOrder = [KeyPathComparator(\SampleFile.state)]
  @State private var selection = Set<SampleFile.ID>()
  @StoredColumns<SampleFile>("samplesTableColumns.2") private var columns

  var body: some View {
    if let files = app.samples[url] {
      VStack(alignment: .leading, spacing: 0) {
        SampleNotices(files: files)
          .padding(8)
        if !files.isEmpty {
          table(files)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
      }
      // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Looking for its samples…").foregroundStyle(.secondary)
      }
      .padding(8)
      // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func table(_ files: [SampleFile]) -> some View {
    Table(files.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("Name", value: \.fileName) { file in Text(file.fileName).lineLimit(1) }
        .width(min: 100, ideal: 220)
        .customizationID("name")
        .disabledCustomizationBehavior(.visibility)
      TableColumn("Status", value: \.state) { file in
        Label(file.state.title, systemImage: file.state.icon)
          .foregroundStyle(file.state.tint)
          .lineLimit(1)
      }
      .width(min: 80, ideal: 130)
      .customizationID("status")
      TableColumn("Location", value: \.location) { file in Text(file.location).lineLimit(1) }
        .width(min: 76, ideal: 110)
        .customizationID("location")
      TableColumn("Size", value: \.size) { file in
        Text(file.size > 0 ? ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) : "")
          .monospacedDigit()
      }
      .width(min: 50, ideal: 66, max: 100)
      .customizationID("size")
      TableColumn("Path", value: \.path) { file in
        Text(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          .help(file.path)
      }
      .width(min: 100, ideal: 320)
      .customizationID("path")
    }
    .contextMenu(forSelectionType: SampleFile.ID.self) { ids in
      let chosen = files.filter { ids.contains($0.id) }
      let found = chosen.filter { $0.state == .found }.map { URL(fileURLWithPath: $0.path) }
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(found) }
        .disabled(found.isEmpty)
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chosen.map(\.path).joined(separator: "\n"), forType: .string)
      }
    }
  }
}

/// What's missing, in words, and what can be done about it.
private struct SampleNotices: View {
  let files: [SampleFile]

  var body: some View {
    let freeze = files.filter { $0.state == .freeze }.count
    let lost = files.filter { $0.state == .lost }.count
    let moved = files.filter { $0.state == .relinkable }.count
    VStack(alignment: .leading, spacing: 6) {
      if freeze + lost + moved == 0 {
        Label(files.isEmpty ? "It doesn't use any samples."
              : "All \(files.count) samples are where the set expects them.",
              systemImage: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      if lost > 0 {
        Label("\(plural(lost, "sample")) can't be found anywhere: not where the set expects, "
              + "and nothing of the same name is in your libraries or Places.",
              systemImage: "exclamationmark.triangle.fill")
          .symbolRenderingMode(.multicolor)
      }
      if moved > 0 {
        Label("\(plural(moved, "sample")) aren't where the set expects, but files with the same "
              + "names are in your libraries or Places. Live's File Manager can likely relink them "
              + "with an automatic search.", systemImage: "arrow.triangle.branch")
      }
      if freeze > 0 {
        Label("\(plural(freeze, "freeze file")) missing. Live freezes those tracks again.",
              systemImage: "snowflake")
          .foregroundStyle(.secondary)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

extension SampleFile.State {
  var icon: String {
    switch self {
    case .lost: return "exclamationmark.triangle.fill"
    case .relinkable: return "arrow.triangle.branch"
    case .freeze: return "snowflake"
    case .found: return "checkmark.circle"
    }
  }

  var tint: Color {
    switch self {
    case .lost: return .red
    case .relinkable: return .orange
    case .freeze, .found: return .secondary
    }
  }
}
