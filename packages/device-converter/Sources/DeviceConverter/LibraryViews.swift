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
          if let batch = app.batch {
            BatchProgressView(run: batch)
          } else {
            switch app.selection {
            case .set(let url):
              SetDetailView(url: url)
            case let item:
              LibrarySummaryView(item: item)
            }
          }
        }
      }
    }
    .frame(minWidth: 920, minHeight: 520)
  }
}

private struct WelcomeView: View {
  @EnvironmentObject var app: AppModel

  var body: some View {
    ContentUnavailableView {
      Label("Ableton Device Converter", systemImage: "slider.horizontal.2.square.on.square")
    } description: {
      Text(app.openError ?? "Open a folder of projects, a project folder, or a single Live Set.")
    } actions: {
      Button("Open…") { app.presentOpenPanel() }
    }
  }
}

/// One set's device view, with its own state object.
private struct SetDetailView: View {
  @EnvironmentObject var app: AppModel
  let url: URL

  var body: some View {
    let model = app.model(for: url)
    ContentView()
      .environmentObject(model)
      .id(ObjectIdentifier(model))
  }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @State private var onlyNeedsWork = false
  @State private var expanded: Set<URL> = []

  private var isSingleProject: Bool {
    if case .project = app.root { return true }
    return false
  }

  private func visible(_ project: ProjectEntry) -> [LiveSetEntry] {
    onlyNeedsWork ? project.sets.filter { app.status(of: $0).kind.needsWork } : project.sets
  }

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $app.selection) {
        Label(isSingleProject ? "All sets" : "All projects", systemImage: "square.stack.3d.up")
          .tag(SidebarItem.overview)

        Section {
          if isSingleProject {
            ForEach(app.projects.flatMap(visible)) { set in
              SetRow(set: set, title: set.name)
            }
          } else {
            ForEach(app.projects) { project in
              projectRow(project)
            }
          }
        }
      }
      .listStyle(.sidebar)
      // Rebuild rather than diff when the filter flips: changing the rows in
      // place triggers AppKit's NSTableView reentrancy warning.
      .id(onlyNeedsWork)

      Divider()
      footer
    }
    .disabled(catalogs.isHostingPlugins)
  }

  @ViewBuilder private func projectRow(_ project: ProjectEntry) -> some View {
    let sets = visible(project)
    if sets.count == 1 && project.sets.count == 1 {
      // Nothing to expand: the project is its one set.
      SetRow(set: sets[0], title: project.name,
             subtitle: sets[0].name == project.name ? nil : sets[0].name)
    } else if !sets.isEmpty {
      DisclosureGroup(isExpanded: isExpanded(project)) {
        ForEach(sets) { set in
          SetRow(set: set, title: set.name)
        }
      } label: {
        let kind = app.rollup(of: project)
        HStack(spacing: 6) {
          StatusIcon(kind: kind)
          Text(project.name).lineLimit(1)
          Spacer(minLength: 4)
          Text("\(project.sets.count) sets").font(.caption).foregroundStyle(.secondary)
        }
        .help("Most urgent: \(kind.title)")
      }
      .tag(SidebarItem.project(project.url))
    }
  }

  private func isExpanded(_ project: ProjectEntry) -> Binding<Bool> {
    Binding {
      expanded.contains(project.url)
    } set: { isOpen in
      if isOpen { expanded.insert(project.url) } else { expanded.remove(project.url) }
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
    }
    .help(status.detail)
    .tag(SidebarItem.set(set.url))
  }
}

private struct StatusIcon: View {
  let kind: SetStatus.Kind

  var body: some View {
    Image(systemName: kind.icon)
      .foregroundStyle(kind.tint)
      .frame(width: 16)
      .accessibilityLabel(kind.title)
  }
}

extension SetStatus.Kind {
  fileprivate var tint: Color {
    switch self {
    case .afterConverting, .converted, .opens: return .green
    case .resaveFirst: return .orange
    case .stuck, .failed: return .red
    case .scanning: return .secondary
    }
  }
}

// MARK: - Summary

/// Status counts and blocking plugins for the whole library or one project.
private struct LibrarySummaryView: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  let item: SidebarItem?
  @State private var showingBatchSheet = false

  private var title: String {
    if case .project(let url) = item, let project = app.projects.first(where: { $0.url == url }) {
      return project.name
    }
    if case .project = app.root, let only = app.projects.first { return only.name }
    return app.root?.url.lastPathComponent ?? ""
  }

  var body: some View {
    let sets = app.sets(in: item)
    let counts = app.counts(in: sets)
    let blocking = app.blockingPlugins(in: sets)

    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.title2.weight(.semibold))
          Text(sets.count == 1 ? "1 set" : "\(sets.count) sets").foregroundStyle(.secondary)
        }

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
          ForEach(SetStatus.Kind.allCases.filter { counts[$0] != nil }, id: \.self) { kind in
            GridRow {
              StatusIcon(kind: kind)
              Text("\(counts[kind] ?? 0)").monospacedDigit().gridColumnAlignment(.trailing)
              VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }

        let candidates = app.batchCandidates(in: sets)
        if !candidates.isEmpty {
          Button("Convert Sets to VST3…") { showingBatchSheet = true }
            .disabled(app.isScanning || catalogs.isLoading)
            .sheet(isPresented: $showingBatchSheet) {
              BatchSheet(candidates: candidates, replacesOrbit: catalogs.substituteOrbit) { chosen, destination in
                showingBatchSheet = false
                app.startBatch(sets: chosen, destination: destination)
              } onCancel: {
                showingBatchSheet = false
              }
            }
        }

        let orbit = app.orbitUsage(in: sets)
        if orbit.sets > 0 {
          OrbitReplacementSection(sets: orbit.sets, devices: orbit.instances)
        }

        if !blocking.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("Plugins holding sets back").font(.headline)
            Text("These have no native build that Live can use. A native update of the top ones frees the most sets.")
              .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
              GridRow {
                Text("Plugin")
                Text("Sets").gridColumnAlignment(.trailing)
                Text("Instances").gridColumnAlignment(.trailing)
                Text("Why")
              }
              .font(.caption).foregroundStyle(.secondary)
              Divider()
              ForEach(blocking) { plugin in
                GridRow {
                  Text(plugin.name)
                  Text("\(plugin.sets)").monospacedDigit()
                  Text("\(plugin.instances)").monospacedDigit().foregroundStyle(.secondary)
                  Text(plugin.reason).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Batch

/// Chooses what a batch converts and where it writes.
/// The opt-in for replacing AMBEO Orbit with dearVR MICRO.
private struct OrbitReplacementSection: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  let sets: Int
  let devices: Int

  private var isInstalled: Bool {
    [DeviceFormat.vst3, .au].contains {
      OrbitToMicro.target(for: $0, vst3: catalogs.vst3, audioUnits: catalogs.audioUnits) != nil
    }
  }

  private var explanation: String {
    "AMBEO Orbit is in \(sets) \(sets == 1 ? "set" : "sets") (\(devices) \(devices == 1 ? "device" : "devices")). "
      + "It's discontinued and Intel only. dearVR MICRO is its successor, and the settings carry over, "
      + "but it doesn't sound the same: placement and tone shift, most at diagonal positions. Each MICRO "
      + "uses its AMBEO Orbit HRTF at Focus 100, followed by a Utility that matches Orbit's loudness for "
      + "that device."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Replacements").font(.headline)
      Toggle("Replace AMBEO Orbit with dearVR MICRO", isOn: $catalogs.substituteOrbit)
        .toggleStyle(.checkbox)
        .disabled(catalogs.isLoading || !isInstalled || catalogs.isHostingPlugins)
      Text(explanation)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 560, alignment: .leading)
      if !catalogs.isLoading && !isInstalled {
        Text("Install dearVR MICRO to use this.").font(.caption).foregroundStyle(.orange)
      }
    }
  }
}

private struct BatchSheet: View {
  let candidates: BatchCandidates
  let replacesOrbit: Bool
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
      Text("Convert \(chosen.count) \(chosen.count == 1 ? "set" : "sets") to VST3")
        .font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        Text(candidates.required.isEmpty
          ? "No sets need converting to open."
          : "\(candidates.required.count) need converting to open")
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

      if replacesOrbit {
        Text("AMBEO Orbit devices will be replaced with dearVR MICRO, which sounds different.")
          .font(.caption).foregroundStyle(.orange)
      }

      Text("Originals are never changed, and existing output files are skipped.")
        .font(.caption).foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        Button("Convert") {
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
