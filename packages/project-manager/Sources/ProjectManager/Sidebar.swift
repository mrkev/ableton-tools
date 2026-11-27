import AppKit
import SwiftUI

/// The library's sidebar: its overview, its plugins, and every project with its sets.
struct LibrarySidebar: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @State private var onlyNeedsWork = false

  private func visible(_ project: ProjectEntry) -> [LiveSetEntry] {
    project.sets.filter {
      (!onlyNeedsWork || app.status(of: $0).kind.needsWork) && app.matchesSearch($0, in: project)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        List(selection: $app.selection) {
          Label("All Projects", systemImage: "square.stack.3d.up")
            .tag(SidebarItem.overview)
          Label("Plugins", systemImage: "puzzlepiece.extension")
            .badge(app.plugins.filter { $0.verdict.rank < 2 }.count)
            .tag(SidebarItem.plugins)

          Section("Projects") {
            ForEach(app.projects) { project in
              ProjectRow(project: project, sets: visible(project))
            }
          }
        }
        .listStyle(.sidebar)
        .searchable(text: $app.searchText, placement: .sidebar, prompt: "Sets, projects, plugins")
        // A set picked elsewhere (a table, the Plugins page) scrolls into view.
        .onChange(of: app.focusedSetURL) { _, url in
          guard let url else { return }
          Task { @MainActor in withAnimation { proxy.scrollTo(SidebarItem.set(url)) } }
        }
        .onAppear {
          if let url = app.focusedSetURL { DispatchQueue.main.async { proxy.scrollTo(SidebarItem.set(url), anchor: .center) } }
        }
      }
      // Rebuild rather than diff when the filter flips: changing the rows in
      // place triggers AppKit's NSTableView reentrancy warning.
      .id(onlyNeedsWork)

      Divider()
      footer
    }
    .disabled(catalogs.isHostingPlugins)
  }

  private var footer: some View {
    VStack(spacing: 8) {
      if app.isScanning {
        ProgressView(value: Double(app.scanned), total: Double(max(app.scanTotal, 1))) {
          Text("Scanning \(app.scanned) of \(app.scanTotal) sets…").font(.caption)
        }
      }
      Toggle("Only sets that need work", isOn: $onlyNeedsWork)
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack {
        Button { app.presentOpenPanel() } label: {
          Label("Open…", systemImage: "folder")
        }
        Spacer()
        Button { app.rescan() } label: {
          Label("Rescan", systemImage: "arrow.clockwise")
        }
        .help("Check for changed files and folders")
      }
    }
    .padding(10)
  }
}

/// A project, opening onto its sets (those the filter and search leave). Hidden
/// when they leave none.
private struct ProjectRow: View {
  @EnvironmentObject var app: AppModel
  let project: ProjectEntry
  let sets: [LiveSetEntry]

  private var isExpanded: Binding<Bool> {
    Binding {
      app.isSearching || app.expandedProjects.contains(project.url)
    } set: { isOpen in
      if isOpen { app.expandedProjects.insert(project.url) } else { app.expandedProjects.remove(project.url) }
    }
  }

  var body: some View {
    if !sets.isEmpty {
      DisclosureGroup(isExpanded: isExpanded) {
        ForEach(sets) { set in
          SetRow(set: set)
          if let copy = set.copyURL {
            CopyRow(set: set, url: copy)
          }
        }
      } label: {
        let kind = app.rollup(of: project)
        HStack(spacing: 6) {
          StatusIcon(kind: kind)
          Text(project.name).lineLimit(1)
        }
        .help("\(plural(project.sets.count, "set")) · most urgent: \(kind.title)")
      }
      .tag(SidebarItem.project(project.url))
      .contextMenu {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
      }
    }
  }
}

private struct SetRow: View {
  @EnvironmentObject var app: AppModel
  let set: LiveSetEntry

  var body: some View {
    let status = app.status(of: set)
    HStack(spacing: 6) {
      StatusIcon(kind: status.kind)
      Text(set.name).lineLimit(1)
      if app.lostSamples(of: set.url) > 0 {
        Spacer(minLength: 4)
        Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.orange)
          .help("\(plural(app.lostSamples(of: set.url), "sample")) can't be found")
          .accessibilityLabel("Missing samples")
      }
    }
    .help(status.detail)
    .contextMenu { SetRowMenu(url: set.url) }
    .tag(SidebarItem.set(set.url))
    .id(SidebarItem.set(set.url))
  }
}

/// A sidebar set's context menu.
private struct SetRowMenu: View {
  @EnvironmentObject var app: AppModel
  let url: URL

  var body: some View {
    OpenInLiveItems(url: url, app: app)
    Divider()
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }
}

/// A fixed copy, under the set it was made from.
private struct CopyRow: View {
  let set: LiveSetEntry
  let url: URL

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: set.copyIsCurrent ? "doc.on.doc" : "clock.badge.exclamationmark")
        .foregroundStyle(set.copyIsCurrent ? Color.secondary : .orange)
        .frame(width: 16)
      Text(set.copyIsCurrent ? "Fixed copy" : "Fixed copy (out of date)")
        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.leading, 18)
    .help(url.lastPathComponent)
    .contextMenu { SetRowMenu(url: url) }
    .tag(SidebarItem.set(url))
    .id(SidebarItem.set(url))
  }
}
