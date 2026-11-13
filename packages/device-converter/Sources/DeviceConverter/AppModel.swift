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
  /// Opted in to replacing AMBEO Orbit with dearVR MICRO. Remembered.
  @Published var substituteOrbit = UserDefaults.standard.bool(forKey: OrbitToMicro.defaultsKey) {
    didSet { UserDefaults.standard.set(substituteOrbit, forKey: OrbitToMicro.defaultsKey) }
  }

  var isLoading: Bool { inventory == nil }

  /// `inventory` with the opt-ins applied.
  var effectiveInventory: PluginInventory? {
    inventory.map {
      var out = $0
      out.substituteOrbit = substituteOrbit
      return out
    }
  }

  /// MICRO for an Orbit device, when opted in and installed.
  func orbitTarget(for device: Device) -> OrbitToMicro.Target? {
    guard OrbitToMicro.isOrbit(device) else { return nil }
    return OrbitToMicro.target(for: device.format, vst3: vst3, audioUnits: audioUnits)
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
  case project(URL)
  case set(URL)
}

/// One row of "which plugins are holding sets back".
struct BlockingPlugin: Identifiable {
  let name: String
  let reason: String
  var sets: Int
  var instances: Int
  var id: String { name }
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
  @Published var selection: SidebarItem? = nil {
    didSet { dropIdleSetModels() }
  }

  private var scans: [URL: LiveSetScan] = [:]
  private var scanFailures: [URL: String] = [:]
  private var cache = LiveSetScanCache.load()
  private var scanTask: Task<Void, Never>?
  private var catalogWatcher: Task<Void, Never>?
  private var optInWatcher: Task<Void, Never>?
  private var setModels: [URL: ConverterModel] = [:]

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
      guard let values = self?.catalogs.$substituteOrbit.dropFirst().values else { return }
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
    if case .set(let set) = opened {
      selection = .set(set)
      return
    }
    selection = .overview
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
  func model(for url: URL) -> ConverterModel {
    if let existing = setModels[url] { return existing }
    let model = ConverterModel(url: url, catalogs: catalogs)
    model.onSaved = { [weak self] in self?.rescan() }
    setModels[url] = model
    return model
  }

  var activeModel: ConverterModel? {
    guard case .set(let url) = selection else { return nil }
    return setModels[url]
  }

  /// A parsed set can take a lot of memory, so idle ones aren't kept around.
  private func dropIdleSetModels() {
    var keep: URL?
    if case .set(let url) = selection { keep = url }
    setModels = setModels.filter { $0.key == keep || $0.value.hasChanges }
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
    let run = BatchController(jobs: jobs, destination: destination, substituteOrbit: catalogs.substituteOrbit)
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

  func dismissBatch() {
    guard batch?.isFinished == true else { return }
    batch = nil
  }

  // MARK: Scanning

  private func startScan() {
    scanTask?.cancel()
    let urls = allSets.flatMap { [$0.url] + ($0.convertedURL.map { [$0] } ?? []) }
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
  }

  func status(of set: LiveSetEntry) -> SetStatus { statuses[set.url] ?? .scanning }

  // MARK: Summaries

  func sets(in item: SidebarItem?) -> [LiveSetEntry] {
    if case .project(let url) = item { return projects.first { $0.url == url }?.sets ?? [] }
    return allSets
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

  /// How many sets use AMBEO Orbit, and how many times.
  func orbitUsage(in sets: [LiveSetEntry]) -> (sets: Int, instances: Int) {
    let counts = sets.compactMap { scans[$0.url] }.map(PluginInventory.orbitCount).filter { $0 > 0 }
    return (counts.count, counts.reduce(0, +))
  }

  /// Plugins keeping sets from opening natively, most sets first.
  func blockingPlugins(in sets: [LiveSetEntry]) -> [BlockingPlugin] {
    var byName: [String: BlockingPlugin] = [:]
    for set in sets {
      guard case .stuck(let plugins, _) = status(of: set) else { continue }
      var seen = Set<String>()
      for plugin in plugins {
        // Formats can name a plugin differently ("TapeStop", "Tape Stop").
        let key = plugin.name.lowercased().filter { $0.isLetter || $0.isNumber }
        var row = byName[key]
          ?? BlockingPlugin(name: plugin.name, reason: plugin.reason, sets: 0, instances: 0)
        row.instances += 1
        if seen.insert(key).inserted { row.sets += 1 }
        byName[key] = row
      }
    }
    return byName.values.sorted {
      ($0.sets, $1.name.lowercased()) > ($1.sets, $0.name.lowercased())
    }
  }
}
