import AppKit
import SwiftUI

/// The window's content: a welcome, one set, or a library with a sidebar.
struct RootView: View {
  @EnvironmentObject var app: AppModel

  var body: some View {
    Group {
      switch app.root {
      case nil:
        WelcomeView()
      case .set(let url):
        SetDetailView(url: url)
      case .library, .project:
        NavigationSplitView {
          LibrarySidebar()
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
        } detail: {
          detail
        }
      }
    }
    .frame(minWidth: 920, minHeight: 520)
    .sheet(item: $app.batchRequest) { request in
      BatchSheet(title: request.title, candidates: request.candidates,
                 replacing: Substitution.allCases.filter(app.catalogs.substitutions.contains)) { chosen, destination in
        app.batchRequest = nil
        app.startBatch(sets: chosen, destination: destination)
      } onCancel: {
        app.batchRequest = nil
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let batch = app.batch {
      BatchProgressView(run: batch)
    } else if app.selection.count > 1 {
      SelectionPage()
    } else {
      switch app.focus {
      case .set(let url)?:
        SetDetailView(url: url)
      case .plugins?:
        PluginsPage()
      case .project(let url)?:
        SetsPage(project: url)
      case .overview?, nil:
        SetsPage(project: nil)
      }
    }
  }
}

private struct WelcomeView: View {
  @EnvironmentObject var app: AppModel

  var body: some View {
    ContentUnavailableView {
      Label("Ableton Projects", systemImage: "slider.horizontal.2.square.on.square")
    } description: {
      Text(app.openError ?? "Open your Projects folder, one project, or a single Live Set.")
    } actions: {
      Button("Open…") { app.presentOpenPanel() }
    }
  }
}

/// One set's page, with its own state object.
private struct SetDetailView: View {
  @EnvironmentObject var app: AppModel
  let url: URL

  var body: some View {
    let model = app.model(for: url)
    SetPageView()
      .environmentObject(model)
      .id(ObjectIdentifier(model))
  }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @State private var onlyNeedsWork = false

  private var isSingleProject: Bool {
    if case .project = app.root { return true }
    return false
  }

  private func visible(_ project: ProjectEntry) -> [LiveSetEntry] {
    project.sets.filter {
      (!onlyNeedsWork || app.status(of: $0).kind.needsWork) && app.matchesSearch($0, in: project)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
      List(selection: $app.selection) {
        Label(isSingleProject ? "All Sets" : "All Projects", systemImage: "square.stack.3d.up")
          .tag(SidebarItem.overview)
        Label("Plugins", systemImage: "puzzlepiece.extension")
          .badge(app.plugins.filter { $0.verdict.rank < 2 }.count)
          .tag(SidebarItem.plugins)

        Section(isSingleProject ? "Sets" : "Projects") {
          if isSingleProject {
            ForEach(app.projects.flatMap(visible)) { set in
              setRows(set, title: set.name)
            }
          } else {
            ForEach(app.projects) { project in
              projectRow(project)
            }
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

  /// A set, and its fixed copy beneath it.
  @ViewBuilder private func setRows(_ set: LiveSetEntry, title: String, subtitle: String? = nil) -> some View {
    SetRow(set: set, title: title, subtitle: subtitle)
    if let copy = set.copyURL {
      CopyRow(set: set, url: copy)
    }
  }

  @ViewBuilder private func projectRow(_ project: ProjectEntry) -> some View {
    let sets = visible(project)
    if sets.count == 1 && project.sets.count == 1 {
      // Nothing to expand: the project is its one set.
      setRows(sets[0], title: project.name, subtitle: sets[0].name == project.name ? nil : sets[0].name)
    } else if !sets.isEmpty {
      DisclosureGroup(isExpanded: isExpanded(project)) {
        ForEach(sets) { set in
          setRows(set, title: set.name)
        }
      } label: {
        let kind = app.rollup(of: project)
        HStack(spacing: 6) {
          StatusIcon(kind: kind)
          Text(project.name).lineLimit(1)
          Spacer(minLength: 4)
          Text("\(project.sets.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .help("\(project.sets.count) sets · most urgent: \(kind.title)")
      }
      .tag(SidebarItem.project(project.url))
    }
  }

  private func isExpanded(_ project: ProjectEntry) -> Binding<Bool> {
    Binding {
      app.isSearching || app.expandedProjects.contains(project.url)
    } set: { isOpen in
      if isOpen { app.expandedProjects.insert(project.url) } else { app.expandedProjects.remove(project.url) }
    }
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

private struct SetRow: View {
  @EnvironmentObject var app: AppModel
  let set: LiveSetEntry
  let title: String
  var subtitle: String?

  var body: some View {
    let status = app.status(of: set)
    HStack(spacing: 6) {
      StatusIcon(kind: status.kind)
      Text(title).lineLimit(1)
      if let subtitle {
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
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
  @EnvironmentObject var app: AppModel
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

struct StatusIcon: View {
  let kind: SetStatus.Kind

  var body: some View {
    Image(systemName: kind.icon)
      .foregroundStyle(kind.tint)
      .frame(width: 16)
      .accessibilityLabel(kind.title)
  }
}

extension SetStatus.Kind {
  var tint: Color {
    switch self {
    case .afterConverting: return .blue
    case .converted, .opens: return .green
    case .resaveFirst: return .orange
    case .stuck, .failed: return .red
    case .scanning: return .secondary
    }
  }
}

// MARK: - Batch

/// Chooses what a batch converts and where it writes.
private struct BatchSheet: View {
  let title: String
  let candidates: BatchCandidates
  /// Opted-in substitutions the batch will make.
  let replacing: [Substitution]
  let onStart: ([LiveSetEntry], BatchDestination) -> Void
  let onCancel: () -> Void

  @AppStorage("batchDestination") private var folderPath = ""
  @State private var includePartial = false
  @State private var includeOptional = false
  @State private var besideOriginals = false

  private var chosen: [LiveSetEntry] {
    candidates.required + (includePartial ? candidates.partial : [])
      + (includeOptional ? candidates.optional : [])
  }

  private var destination: BatchDestination? {
    if besideOriginals { return .besideOriginals }
    return folderPath.isEmpty ? nil : .folder(URL(fileURLWithPath: folderPath))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Fix \(plural(chosen.count, "set"))").font(.headline)
        Text(title).font(.caption).foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(candidates.required.isEmpty
          ? "No sets here need fixing to open."
          : "\(candidates.required.count) need fixing to open")
        if !candidates.partial.isEmpty {
          Toggle("Also \(candidates.partial.count) stuck on other plugins", isOn: $includePartial)
            .toggleStyle(.checkbox)
          Text("Converts what it can, but they still won't open fully.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !candidates.optional.isEmpty {
          Toggle("Also \(candidates.optional.count) that already open", isOn: $includeOptional)
            .toggleStyle(.checkbox)
          Text("Their VST2 plugins are native, so this only moves them to VST3 for the future.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Save new files to").font(.subheadline.weight(.medium))
        Picker("Save new files to", selection: $besideOriginals) {
          Text("Another folder").tag(false)
          Text("Next to each original").tag(true)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()

        if besideOriginals {
          Text("Adds a -vst3.als file to each project folder, and the library marks those sets converted.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          HStack {
            Text(folderPath.isEmpty ? "No folder chosen" : folderPath)
              .font(.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseFolder() }
          }
          Text("Project folders stay untouched, and the library won't mark these sets converted.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      ForEach(replacing) { sub in
        Text("\(sub.sourceName) devices will be replaced with \(sub.targetName), which doesn't sound identical.")
          .font(.caption).foregroundStyle(.orange)
      }

      Text("Originals are never changed, and existing output files are skipped.")
        .font(.caption).foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        Button("Fix") {
          if let destination { onStart(chosen, destination) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(destination == nil || chosen.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 480)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
  }
}

/// A batch's progress, then its per-set results.
private struct BatchProgressView: View {
  @EnvironmentObject var app: AppModel
  @ObservedObject var run: BatchController

  private func count(_ matches: (BatchSetResult.Outcome) -> Bool) -> Int {
    run.results.filter { matches($0.outcome) }.count
  }

  private var converted: Int {
    count { if case .converted = $0 { return true } else { return false } }
  }
  private var skipped: Int {
    count { if case .skipped = $0 { return true } else { return false } }
  }
  private var failed: Int {
    count { if case .failed = $0 { return true } else { return false } }
  }

  private var title: String {
    if !run.isFinished { return run.isCancelled ? "Cancelling…" : "Converting sets" }
    return run.isCancelled ? "Batch cancelled" : "Batch finished"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.title2.weight(.semibold))
      ProgressView(value: Double(run.results.count), total: Double(max(run.jobs.count, 1)))
      Text(run.isFinished ? totals : "\(run.results.count) of \(run.jobs.count) · \(run.currentStep)")
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)

      List(run.results.reversed()) { result in
        HStack(spacing: 8) {
          outcomeIcon(result.outcome)
          Text(result.set.name).lineLimit(1)
          Spacer(minLength: 8)
          Text(result.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(notes(of: result))
      }
      .listStyle(.plain)

      HStack {
        Spacer()
        if run.isFinished {
          if case .folder(let folder) = run.destination, converted > 0 {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
          }
          Button("Done") { app.dismissBatch() }.keyboardShortcut(.defaultAction)
        } else {
          Button("Cancel") { run.cancel() }.disabled(run.isCancelled)
        }
      }
    }
    .padding(24)
  }

  private var totals: String {
    let notStarted = run.jobs.count - run.results.count
    return "\(converted) converted · \(skipped) skipped · \(failed) failed"
      + (notStarted > 0 ? " · \(notStarted) not started" : "")
  }

  private func notes(of result: BatchSetResult) -> String {
    if case .converted(let output, _, _, _, _, let notes) = result.outcome {
      return ([output.path] + notes).joined(separator: "\n")
    }
    return result.summary
  }

  @ViewBuilder private func outcomeIcon(_ outcome: BatchSetResult.Outcome) -> some View {
    switch outcome {
    case .converted:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Converted")
    case .skipped:
      Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Skipped")
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
    }
  }
}
