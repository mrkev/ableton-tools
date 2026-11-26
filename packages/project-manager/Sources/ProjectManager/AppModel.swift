import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Installed plugins, shared by every open set.
@MainActor
final class PluginCatalogs: ObservableObject {
  @Published private(set) var audioUnits: [AudioUnitInfo] = []
  @Published private(set) var isLoadingAudioUnits = true
  @Published private(set) var vst3: [Vst3PluginInfo] = []
  @Published private(set) var isLoadingVst3 = true
  /// Everything installed, once all of it is known.
  @Published private(set) var inventory: PluginInventory?
  /// A save or batch is converting. Only one conversion runs at a time, and the
  /// UI that could start another is disabled meanwhile.
  @Published var isHostingPlugins = false
  /// Opted-in replacements of plugins by different ones. Remembered.
  @Published var substitutions = Set(Substitution.allCases.filter { UserDefaults.standard.bool(forKey: $0.defaultsKey) }) {
    didSet {
      for s in Substitution.allCases { UserDefaults.standard.set(substitutions.contains(s), forKey: s.defaultsKey) }
    }
  }

  func isOptedIn(_ s: Substitution) -> Binding<Bool> {
    Binding(get: { self.substitutions.contains(s) }, set: { on in
      if on { self.substitutions.insert(s) } else { self.substitutions.remove(s) }
    })
  }

  var isLoading: Bool { inventory == nil }

  /// `inventory` with the opt-ins applied.
  var effectiveInventory: PluginInventory? {
    inventory.map {
      var out = $0
      out.substitutions = substitutions
      return out
    }
  }

  /// The replacement installed for a device, opted in or not (a device can be
  /// replaced on its own).
  func substitution(for device: Device) -> (Substitution, PluginTarget)? {
    guard let s = Substitution.matching(device),
          let target = s.target(for: device.format, vst3: vst3, audioUnits: audioUnits) else { return nil }
    return (s, target)
  }

  init() {
    Task {
      let others = await Task.detached(priority: .userInitiated) {
        (AudioUnitCatalog.installed(), PluginInventory.vst2Bundles(), PluginInventory.vst3BundleArchitectures())
      }.value
      audioUnits = others.0
      isLoadingAudioUnits = false
      // On the main actor (plugins expect their code to load on the main thread),
      // yielding between bundles so the window stays responsive.
      var found: [Vst3PluginInfo] = []
      for bundle in Vst3Catalog.bundles() {
        found += Vst3Catalog.classes(in: bundle)
        await Task.yield()
      }
      vst3 = found
      isLoadingVst3 = false
      inventory = PluginInventory(vst3: found, vst3Bundles: others.2, vst2Files: others.1, audioUnits: others.0)
    }
  }
}

enum SidebarItem: Hashable {
  case overview
  case plugins
  case project(URL)
  /// A set, or a set's fixed copy.
  case set(URL)
}

/// A set page's place in the library.
struct SetContext {
  let url: URL
  /// The library's entry, for an original.
  let entry: LiveSetEntry?
  let project: ProjectEntry?
  /// For a fixed copy, the set it was made from.
  let original: LiveSetEntry?
}

/// Sets a batch could fix, for the sheet that starts it.
struct BatchRequest: Identifiable {
  let id = UUID()
  let title: String
  let candidates: BatchCandidates
}

/// What a batch could convert within some sets.
struct BatchCandidates {
  /// Need converting to open.
  var required: [LiveSetEntry] = []
  /// Could convert some devices, but stay stuck on other plugins.
  var partial: [LiveSetEntry] = []
  /// Already open, with VST2 devices that could move to VST3 anyway.
  var optional: [LiveSetEntry] = []

  var isEmpty: Bool { required.isEmpty && partial.isEmpty && optional.isEmpty }
}

/// What's open: a library or project (with its sets' statuses), or a single set.
@MainActor
final class AppModel: ObservableObject {
  let catalogs = PluginCatalogs()

  @Published private(set) var root: OpenedRoot?
  @Published private(set) var projects: [ProjectEntry] = []
  @Published private(set) var statuses: [URL: SetStatus] = [:]
  @Published private(set) var scanned = 0
  @Published private(set) var scanTotal = 0
  @Published private(set) var openError: String?
  /// The batch in progress, or finished and not yet dismissed.
  @Published private(set) var batch: BatchController?
  @Published var selection: Set<SidebarItem> = [] {
    didSet { dropIdleSetModels() }
  }
  /// Projects open in the sidebar.
  @Published var expandedProjects: Set<URL> = []
  /// Filters the sidebar and tables by set, project or plugin name.
  @Published var searchText = ""
  /// The batch sheet, while it's up.
  @Published var batchRequest: BatchRequest?
  /// Samples not where the set expects them, by set or copy URL.
  @Published private(set) var missingSamples: [URL: [MissingSample]] = [:]
  /// Every plugin in the library's sets.
  @Published private(set) var plugins: [PluginUsage] = []
  /// Bytes on disk, per project folder, once measured.
  @Published private(set) var projectSizes: [URL: Int64] = [:]

  private var scans: [URL: LiveSetScan] = [:]
  private var scanFailures: [URL: String] = [:]
  private var cache = LiveSetScanCache.load()
  private var scanTask: Task<Void, Never>?
  private var catalogWatcher: Task<Void, Never>?
  private var optInWatcher: Task<Void, Never>?
  private var setModels: [URL: SetModel] = [:]
  private var sampleTask: Task<Void, Never>?
  private var sizeTasks: Set<URL> = []

  var isScanning: Bool { scanned < scanTotal }
  var allSets: [LiveSetEntry] { projects.flatMap(\.sets) }

  init() {
    // Statuses depend on what's installed, which takes a moment to learn.
    catalogWatcher = Task { [weak self] in
      guard let values = self?.catalogs.$inventory.values else { return }
      for await inventory in values where inventory != nil {
        self?.recomputeStatuses()
        break
      }
    }
    optInWatcher = Task { [weak self] in
      guard let values = self?.catalogs.$substitutions.dropFirst().values else { return }
      for await _ in values {
        // @Published delivers before the property changes.
        await Task.yield()
        self?.recomputeStatuses()
      }
    }
  }

  // MARK: Opening

  func presentOpenPanel() {
    guard !catalogs.isHostingPlugins else { return }
    let panel = NSOpenPanel()
    panel.message = "Choose a folder of projects, a project folder, or a Live Set."
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowedContentTypes = [UTType(filenameExtension: "als") ?? .data, .folder]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { open(url: url) }
  }

  func open(url: URL) {
    guard !catalogs.isHostingPlugins else { return }
    guard let opened = LibraryDiscovery.classify(url) else {
      openError = "No Live Sets found in “\(url.lastPathComponent)”."
      return
    }
    openError = nil
    scanTask?.cancel()
    setModels = [:]
    scans = [:]
    scanFailures = [:]
    statuses = [:]
    root = opened
    projects = LibraryDiscovery.projects(for: opened)
    missingSamples = [:]
    plugins = []
    projectSizes = [:]
    if case .set(let set) = opened {
      selection = [.set(set)]
      checkSamples(of: [set])
      return
    }
    selection = [.overview]
    startScan()
  }

  /// Re-read folders and any files that changed. Choices in open sets are kept,
  /// unless their file changed underneath them with nothing queued.
  func rescan() {
    guard let root, !catalogs.isHostingPlugins else { return }
    setModels = setModels.filter { !$0.value.isStaleOnDisk || $0.value.hasChanges }
    objectWillChange.send()
    projects = LibraryDiscovery.projects(for: root)
    startScan()
  }

  // MARK: Set models

  /// A set's state, kept while it's selected or has choices queued.
  func model(for url: URL) -> SetModel {
    if let existing = setModels[url] { return existing }
    let model = SetModel(url: url, catalogs: catalogs)
    model.onSaved = { [weak self] in self?.rescan() }
    setModels[url] = model
    return model
  }

  /// The one thing selected, when only one is.
  var focus: SidebarItem? { selection.count == 1 ? selection.first : nil }

  var focusedSetURL: URL? {
    if case .set(let url)? = focus { return url }
    return nil
  }

  var activeModel: SetModel? { focusedSetURL.flatMap { setModels[$0] } }

  /// A parsed set can take a lot of memory, so idle ones aren't kept around.
  private func dropIdleSetModels() {
    let keep = focusedSetURL
    setModels = setModels.filter { $0.key == keep || $0.value.hasChanges }
  }

  /// Where a set or copy sits in the library.
  func context(for url: URL) -> SetContext {
    for project in projects {
      for set in project.sets {
        if set.url == url { return SetContext(url: url, entry: set, project: project, original: nil) }
        if set.copyURL == url { return SetContext(url: url, entry: nil, project: project, original: set) }
      }
    }
    return SetContext(url: url, entry: nil, project: nil, original: nil)
  }

  /// Selects a set (or copy) and opens its project in the sidebar.
  func reveal(_ url: URL) {
    if let project = context(for: url).project { expandedProjects.insert(project.url) }
    selection = [.set(url)]
  }

  func scan(of url: URL) -> LiveSetScan? { scans[url] }

  /// Sets picked in the sidebar, when several are.
  var selectedSets: [LiveSetEntry] {
    let urls = Set(selection.compactMap { item -> URL? in
      if case .set(let url) = item { return url }
      return nil
    })
    let projectURLs = Set(selection.compactMap { item -> URL? in
      if case .project(let url) = item { return url }
      return nil
    })
    return projects.flatMap { project in
      projectURLs.contains(project.url) ? project.sets : project.sets.filter { urls.contains($0.url) }
    }
  }

  // MARK: Search

  var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

  /// A set matches by its name, its project's, or a plugin it uses.
  func matchesSearch(_ set: LiveSetEntry, in project: ProjectEntry) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    if set.name.localizedCaseInsensitiveContains(query) || project.name.localizedCaseInsensitiveContains(query) {
      return true
    }
    guard let scan = scans[set.url] else { return false }
    return scan.vst2.contains { $0.name.localizedCaseInsensitiveContains(query) }
      || scan.vst3.contains { $0.name.localizedCaseInsensitiveContains(query) }
      || scan.au.contains { $0.name.localizedCaseInsensitiveContains(query) }
  }

  // MARK: Project folders

  /// Measures a project folder's size in the background, once.
  func measure(_ project: ProjectEntry) {
    guard projectSizes[project.url] == nil, sizeTasks.insert(project.url).inserted else { return }
    let url = project.url
    Task {
      let size = await Task.detached(priority: .utility) { Self.folderSize(url) }.value
      projectSizes[url] = size
      sizeTasks.remove(url)
    }
  }

  private nonisolated static func folderSize(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in e {
      let values = try? file.resourceValues(forKeys: Set(keys))
      if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
    }
    return total
  }

  // MARK: Batch conversion

  func startBatch(sets: [LiveSetEntry], destination: BatchDestination) {
    guard !catalogs.isHostingPlugins, !sets.isEmpty else { return }
    // A set with choices queued converts the way it was set up.
    let jobs = sets.map { set in
      BatchJob(set: set, choices: setModels[set.url].flatMap { model in
        model.hasChanges
          ? model.devices.map { BatchJob.Choice(product: $0.product, action: model.action(for: $0)) } : nil
      })
    }
    let run = BatchController(jobs: jobs, destination: destination, substitutions: catalogs.substitutions)
    batch = run
    catalogs.isHostingPlugins = true
    Task {
      await run.run()
      catalogs.isHostingPlugins = false
      for result in run.results {
        if case .converted = result.outcome { setModels[result.set.url] = nil }
      }
      if destination == .besideOriginals { rescan() }
    }
  }

  /// Asks what to fix in `sets` and where to save, then starts a batch.
  func presentBatch(for sets: [LiveSetEntry], title: String) {
    guard !catalogs.isHostingPlugins else { return }
    batchRequest = BatchRequest(title: title, candidates: batchCandidates(in: sets))
  }

  /// The sets the menu's bulk fix applies to: those picked, or what's shown.
  var batchScope: (sets: [LiveSetEntry], title: String) {
    if selection.count > 1 { return (selectedSets, "\(selectedSets.count) selected sets") }
    if case .project(let url)? = focus, let project = projects.first(where: { $0.url == url }) {
      return (project.sets, project.name)
    }
    return (allSets, root?.url.lastPathComponent ?? "Library")
  }

  func dismissBatch() {
    guard batch?.isFinished == true else { return }
    batch = nil
  }

  // MARK: Scanning

  private func startScan() {
    scanTask?.cancel()
    let urls = allSets.flatMap { [$0.url] + ($0.copyURL.map { [$0] } ?? []) }
    var pending: [URL] = []
    scanFailures = [:]
    for url in urls {
      if let hit = cache.lookup(url) { scans[url] = hit } else { pending.append(url) }
    }
    scanTotal = urls.count
    scanned = urls.count - pending.count
    recomputeStatuses()
    guard !pending.isEmpty else {
      cache.save()
      checkSamples(of: urls)
      return
    }

    let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    scanTask = Task { [weak self] in
      await withTaskGroup(of: (URL, Result<LiveSetScan, Error>)?.self) { group in
        var queue = pending[...]
        for _ in 0..<limit {
          guard let url = queue.popFirst() else { break }
          group.addTask(priority: .utility) { Self.scanOffMain(url) }
        }
        var sinceFlush = 0
        for await result in group {
          guard let self, !Task.isCancelled else {
            group.cancelAll()
            return
          }
          if let (url, outcome) = result {
            switch outcome {
            case .success(let scan):
              self.scans[url] = scan
              self.cache.store(scan, for: url)
            case .failure(let error):
              self.scanFailures[url] = String(describing: error)
            }
          }
          self.scanned += 1
          sinceFlush += 1
          if sinceFlush >= 8 {
            sinceFlush = 0
            self.recomputeStatuses()
          }
          if let url = queue.popFirst() {
            group.addTask(priority: .utility) { Self.scanOffMain(url) }
          }
        }
      }
      guard let self, !Task.isCancelled else { return }
      self.recomputeStatuses()
      self.cache.save()
      self.checkSamples(of: urls)
    }
  }

  /// Looks for every set's samples, off the main thread. A single opened set is
  /// scanned here first, since it isn't part of a library scan.
  private func checkSamples(of urls: [URL]) {
    sampleTask?.cancel()
    let known = scans
    sampleTask = Task { [weak self] in
      let found = await Task.detached(priority: .utility) { () -> [URL: [MissingSample]] in
        let locations = LiveLocations.current()
        let index = SampleIndex.build(locations)
        var out: [URL: [MissingSample]] = [:]
        for url in urls {
          if Task.isCancelled { break }
          guard let scan = known[url] ?? (try? LiveSetScanner.scan(url: url)) else { continue }
          out[url] = locations.missing(in: scan, setURL: url, index: index)
        }
        return out
      }.value
      guard let self, !Task.isCancelled else { return }
      self.missingSamples = found
    }
  }

  private nonisolated static func scanOffMain(_ url: URL) -> (URL, Result<LiveSetScan, Error>)? {
    guard !Task.isCancelled else { return nil }
    return (url, Result { try LiveSetScanner.scan(url: url) })
  }

  private func recomputeStatuses() {
    var out: [URL: SetStatus] = [:]
    for set in allSets {
      if let why = scanFailures[set.url] {
        out[set.url] = .failed(why)
      } else if let scan = scans[set.url] {
        out[set.url] = catalogs.effectiveInventory.map {
          SetStatus.resolve(
            scan: scan, convertedScan: set.convertedURL.flatMap { scans[$0] },
            hasConversion: set.convertedURL != nil, inventory: $0)
        } ?? .scanning
      } else {
        out[set.url] = .scanning
      }
    }
    statuses = out
    if let inventory = catalogs.inventory {
      plugins = PluginIndex.build(sets: allSets.compactMap { set in scans[set.url].map { (set.url, $0) } },
                                  inventory: inventory)
    }
  }

  /// A fixed copy is judged on its own: does it open?
  func copyStatus(of set: LiveSetEntry) -> SetStatus? {
    guard let copy = set.copyURL else { return nil }
    guard let scan = scans[copy], let inventory = catalogs.effectiveInventory else { return .scanning }
    return SetStatus.resolve(scan: scan, convertedScan: nil, hasConversion: false, inventory: inventory)
  }

  /// The status of whatever a set page shows.
  func status(of url: URL) -> SetStatus {
    if let status = statuses[url] { return status }
    let context = context(for: url)
    if let original = context.original { return copyStatus(of: original) ?? .scanning }
    guard let scan = scans[url], let inventory = catalogs.effectiveInventory else { return .scanning }
    return SetStatus.resolve(scan: scan, convertedScan: nil, hasConversion: false, inventory: inventory)
  }

  /// Missing samples that nothing of the same name could stand in for.
  func lostSamples(of url: URL) -> Int {
    missingSamples[url]?.filter { !$0.isFreeze && !$0.hasNamesake }.count ?? 0
  }

  func status(of set: LiveSetEntry) -> SetStatus { statuses[set.url] ?? .scanning }

  // MARK: Summaries

  func sets(in item: SidebarItem?) -> [LiveSetEntry] {
    if case .project(let url) = item { return projects.first { $0.url == url }?.sets ?? [] }
    return allSets
  }

  /// A single opened set has no library scan; read it once for its page.
  func scanIfNeeded(_ url: URL) {
    guard scans[url] == nil, scanFailures[url] == nil else { return }
    Task {
      let result = await Task.detached(priority: .userInitiated) { Result { try LiveSetScanner.scan(url: url) } }.value
      switch result {
      case .success(let scan): scans[url] = scan
      case .failure(let error): scanFailures[url] = String(describing: error)
      }
      objectWillChange.send()
    }
  }

  func counts(in sets: [LiveSetEntry]) -> [SetStatus.Kind: Int] {
    sets.reduce(into: [:]) { $0[status(of: $1).kind, default: 0] += 1 }
  }

  /// The most urgent status among a project's sets.
  func rollup(of project: ProjectEntry) -> SetStatus.Kind {
    project.sets.map { status(of: $0).kind }.min() ?? .opens
  }

  func batchCandidates(in sets: [LiveSetEntry]) -> BatchCandidates {
    var out = BatchCandidates()
    for set in sets {
      switch status(of: set) {
      case .afterConverting: out.required.append(set)
      case .stuck(_, let convertible) where convertible > 0: out.partial.append(set)
      case .opens(let convertible) where convertible > 0: out.optional.append(set)
      default: break
      }
    }
    return out
  }

  /// How many sets a substitution's source plugin is in, and how many times.
  func usage(of s: Substitution, in sets: [LiveSetEntry]) -> (sets: Int, instances: Int) {
    let counts = sets.compactMap { scans[$0.url] }.map { PluginInventory.count(of: s, in: $0) }.filter { $0 > 0 }
    return (counts.count, counts.reduce(0, +))
  }
}
