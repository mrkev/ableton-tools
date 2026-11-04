import Foundation

/// Where a batch writes its `<name>-vst3.als` files.
enum BatchDestination: Equatable {
  /// In each set's project folder, where the library marks the set converted.
  case besideOriginals
  /// Under `<folder>/<project folder>/`. Keeps the project folders untouched.
  case folder(URL)

  func output(for set: LiveSetEntry) -> URL {
    let name = set.name + LibraryDiscovery.convertedSuffix + ".als"
    let project = set.url.deletingLastPathComponent()
    switch self {
    case .besideOriginals:
      return project.appendingPathComponent(name)
    case .folder(let root):
      return root.appendingPathComponent(project.lastPathComponent).appendingPathComponent(name)
    }
  }
}

/// How one set in a batch ended up.
struct BatchSetResult: Identifiable, Codable {
  enum Outcome: Codable {
    case converted(output: URL, toVst3: Int, toAU: Int, vst2Left: Int, notes: [String])
    case skipped(String)
    case failed(String)
  }

  let set: LiveSetEntry
  let outcome: Outcome
  var id: URL { self.set.url }

  var summary: String {
    switch outcome {
    case .converted(_, let toVst3, let toAU, let left, let notes):
      return ["\(toVst3) to VST3"]
        .appending(toAU > 0, "\(toAU) to AU")
        .appending(left > 0, "\(left) VST2 left")
        .appending(!notes.isEmpty, "\(notes.count) note(s)")
        .joined(separator: " · ")
    case .skipped(let why), .failed(let why):
      return why
    }
  }
}

private extension Array where Element == String {
  func appending(_ condition: Bool, _ text: String) -> [String] { condition ? self + [text] : self }
}

/// One set to convert.
struct BatchJob: Codable {
  struct Choice: Codable {
    let product: String
    let action: SlotAction
  }

  let set: LiveSetEntry
  /// The user's per-device choices for this set, by device position. `nil`
  /// converts every VST2 device that has a usable VST3.
  let choices: [Choice]?
}

/// Converts sets one after another, writing new files, in this process. Originals
/// are only read, an existing output is never overwritten (so an interrupted run
/// can simply be run again), and each output is re-read before it counts as done.
///
/// The GUI runs this through `BatchController`, in a worker process.
@MainActor
final class BatchRun {
  let jobs: [BatchJob]
  let destination: BatchDestination
  private let catalog: [Vst3PluginInfo]
  var onStep: ((String) -> Void)?
  var onResult: ((BatchSetResult) -> Void)?

  init(jobs: [BatchJob], destination: BatchDestination, catalog: [Vst3PluginInfo]) {
    self.jobs = jobs
    self.destination = destination
    self.catalog = catalog
  }

  func run() async {
    for job in jobs {
      let outcome = await convert(job)
      onResult?(BatchSetResult(set: job.set, outcome: outcome))
    }
  }

  private func convert(_ job: BatchJob) async -> BatchSetResult.Outcome {
    let source = job.set.url
    let output = destination.output(for: job.set)
    guard output.standardizedFileURL != source.standardizedFileURL else {
      return .failed("output would overwrite the original")
    }
    guard !FileManager.default.fileExists(atPath: output.path) else {
      return .skipped("\(output.lastPathComponent) already exists")
    }

    onStep?("Opening \(job.set.name)…")
    await Task.yield()
    let loaded = await Task.detached(priority: .userInitiated) {
      () -> Result<(AlsDocument, [Device], Set<String>), Error> in
      Result {
        let doc = try AlsDocument(url: source)
        return (doc, DeviceExtractor.extractAll(doc.root), doc.automatedTargetIds)
      }
    }.value
    guard case .success(let (doc, devices, automated)) = loaded else {
      if case .failure(let error) = loaded { return .failed("couldn't open: \(error)") }
      return .failed("couldn't open")
    }
    guard !doc.predatesVst3 else { return .skipped("saved by \(doc.creator): re-save in Live 10+ first") }

    let plan: [(Device, SlotAction)]
    if let choices = job.choices {
      guard choices.map(\.product) == devices.map(\.product) else {
        return .skipped("the set changed since its choices were made")
      }
      plan = zip(devices, choices).compactMap { $1.action == .keep ? nil : ($0, $1.action) }
    } else {
      plan = devices.compactMap { device in
        guard device.format == .vst, case .available(let target) = Vst3Availability.resolve(
          LiveSetScan.Vst2Plugin(
            name: device.product, uniqueId: Vst3Migration.vst2UniqueId(device),
            isChunk: Vst2State.isChunkPreset(device.element)),
          catalog: catalog) else { return nil }
        return (device, .replaceVST3(target))
      }
    }
    guard !plan.isEmpty else { return .skipped("nothing to convert") }

    var toVst3 = 0, toAU = 0, vst2Converted = 0
    var notes: [String] = []
    for (i, (device, action)) in plan.enumerated() {
      onStep?("\(job.set.name): \(device.name) (\(i + 1)/\(plan.count))")
      await Task.yield()
      let label = "\(device.trackName) › \(device.name)"
      let replacement: XMLElement
      switch action {
      case .keep:
        continue
      case .replaceAU(let au):
        replacement = DeviceBuilder.makeAUDevice(from: device, target: au)
        toAU += 1
      case .replaceVST3(let target):
        do {
          let c = try Vst3Migration.prepare(device, target: target, automatedTargets: automated)
          replacement = DeviceBuilder.makeVst3Device(from: device, conversion: c)
          toVst3 += 1
          notes += c.warnings.map { "\(label): \($0)" }
        } catch {
          notes.append("\(label): not converted: \(error)")
          continue
        }
      }
      if device.format == .vst { vst2Converted += 1 }
      device.parent.replaceChild(at: device.element.index, with: replacement)
    }
    guard toVst3 + toAU > 0 else { return .failed(notes.first ?? "nothing could be converted") }

    onStep?("Writing \(output.lastPathComponent)…")
    await Task.yield()
    let vst2Before = devices.filter { $0.format == .vst }.count
    let vst3Before = devices.filter { $0.format == .vst3 }.count
    let auBefore = devices.filter { $0.format == .au }.count
    let vst2Left = vst2Before - vst2Converted
    let written = await Task.detached(priority: .userInitiated) { () -> Result<LiveSetScan, Error> in
      Result {
        try FileManager.default.createDirectory(
          at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try doc.serialized().write(to: output, options: .atomic)
        return try LiveSetScanner.scan(url: output)
      }
    }.value

    switch written {
    case .failure(let error):
      return .failed("couldn't write: \(error)")
    case .success(let scan):
      guard scan.vst2.count == vst2Left, scan.vst3.count == vst3Before + toVst3,
            scan.au.count == auBefore + toAU else {
        try? FileManager.default.removeItem(at: output)
        return .failed("output didn't verify, so it was removed")
      }
      return .converted(output: output, toVst3: toVst3, toAU: toAU, vst2Left: vst2Left, notes: notes)
    }
  }
}

/// Headless batch conversion:
///
///     DeviceConverter --batch <folder> (--out-dir <dir> | --beside-originals)
///                     [--include-partial] [--include-native] [--dry-run]
///
/// Converts the sets that need it to open natively. `--include-partial` adds sets
/// stuck on other plugins; `--include-native` adds sets that already open.
///
/// There's deliberately no default destination: writing into project folders
/// has to be asked for.
enum BatchCli {
  private static let usage = "usage: DeviceConverter --batch <folder> "
    + "(--out-dir <dir> | --beside-originals) [--include-partial] [--include-native] [--dry-run]"

  @MainActor static func run(arguments args: [String]) async -> Int32 {
    setlinebuf(stdout)
    guard let i = args.firstIndex(of: "--batch"), i + 1 < args.count else {
      print(usage)
      return 2
    }
    let destination: BatchDestination
    if let o = args.firstIndex(of: "--out-dir"), o + 1 < args.count {
      destination = .folder(URL(fileURLWithPath: args[o + 1]))
    } else if args.contains("--beside-originals") {
      destination = .besideOriginals
    } else {
      print(usage)
      return 2
    }

    let folder = URL(fileURLWithPath: args[i + 1])
    guard let root = LibraryDiscovery.classify(folder), root != .set(folder) else {
      print("no projects found in \(folder.path)")
      return 1
    }
    let inventory = PluginInventory.loadNow()
    let includePartial = args.contains("--include-partial")
    let includeOptional = args.contains("--include-native")
    var jobs: [BatchJob] = []
    var unreadable = 0
    for set in LibraryDiscovery.projects(for: root).flatMap(\.sets) {
      guard let scan = try? LiveSetScanner.scan(url: set.url) else {
        unreadable += 1
        continue
      }
      let converted = set.convertedURL.flatMap { try? LiveSetScanner.scan(url: $0) }
      let wanted: Bool
      switch SetStatus.resolve(
        scan: scan, convertedScan: converted, hasConversion: set.convertedURL != nil, inventory: inventory) {
      case .afterConverting: wanted = true
      case .stuck(_, let convertible): wanted = includePartial && convertible > 0
      case .opens(let convertible): wanted = includeOptional && convertible > 0
      default: wanted = false
      }
      if wanted { jobs.append(BatchJob(set: set, choices: nil)) }
    }
    print("\(jobs.count) set(s) to convert" + (unreadable > 0 ? ", \(unreadable) unreadable" : ""))

    if args.contains("--dry-run") {
      for job in jobs { print("  \(job.set.url.path) → \(destination.output(for: job.set).path)") }
      return 0
    }

    let run = BatchRun(jobs: jobs, destination: destination, catalog: inventory.vst3)
    var converted = 0, skipped = 0, failed = 0
    run.onResult = { result in
      switch result.outcome {
      case .converted(_, _, _, _, let notes):
        converted += 1
        print("  ✓ \(result.set.name): \(result.summary)")
        for note in notes { print("      ⚠︎ \(note)") }
      case .skipped:
        skipped += 1
        print("  – \(result.set.name): \(result.summary)")
      case .failed:
        failed += 1
        print("  ✗ \(result.set.name): \(result.summary)")
      }
    }
    await run.run()
    print("converted \(converted), skipped \(skipped), failed \(failed)")
    return failed == 0 ? 0 : 1
  }
}

// MARK: - Worker process

/// What the GUI sends a worker on stdin.
struct BatchWorkerRequest: Codable {
  let jobs: [BatchJob]
  /// `nil` writes beside the originals.
  let folder: URL?
}

/// What a worker reports on stdout, one prefixed JSON object per line. The prefix
/// tells these apart from anything a plugin prints.
enum BatchWorkerEvent: Codable {
  case step(String)
  case result(BatchSetResult)

  static let linePrefix = "@@batch "
}

enum BatchWorker {
  /// `--batch-worker`: run the request from stdin, reporting on stdout.
  @MainActor static func run() async -> Int32 {
    setlinebuf(stdout)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let request = try? JSONDecoder().decode(BatchWorkerRequest.self, from: input) else { return 2 }
    let run = BatchRun(
      jobs: request.jobs, destination: request.folder.map { .folder($0) } ?? .besideOriginals,
      catalog: Vst3Catalog.installed())
    run.onStep = { emit(.step($0)) }
    run.onResult = { emit(.result($0)) }
    await run.run()
    return 0
  }

  private static func emit(_ event: BatchWorkerEvent) {
    guard let data = try? JSONEncoder().encode(event) else { return }
    print(BatchWorkerEvent.linePrefix + String(decoding: data, as: UTF8.self))
  }
}

/// Runs a batch for the GUI in a child process, because hosting plugins in the app
/// itself goes badly: with the window hidden behind another app, loading a Serum
/// patch took minutes rather than about a second from a windowless process, spent in
/// Serum's short sleeps while it waits on its audio engine (`beginActivity` didn't
/// help). The main thread is stuck meanwhile, so Cancel can't respond, and a plugin
/// crash would take the app with it.
@MainActor
final class BatchController: ObservableObject {
  let jobs: [BatchJob]
  let destination: BatchDestination

  @Published private(set) var results: [BatchSetResult] = []
  @Published private(set) var currentStep = ""
  @Published private(set) var isFinished = false
  @Published private(set) var isCancelled = false
  private var worker: Process?

  init(jobs: [BatchJob], destination: BatchDestination) {
    self.jobs = jobs
    self.destination = destination
  }

  /// Stops the worker now. Outputs are written atomically, so the set in progress
  /// simply isn't written.
  func cancel() {
    isCancelled = true
    worker?.terminate()
  }

  func run() async {
    var remaining = jobs[...]
    while !remaining.isEmpty, !isCancelled {
      let before = results.count
      let succeeded = await runWorker(for: Array(remaining))
      remaining = remaining.dropFirst(results.count - before)
      if isCancelled { break }
      guard !succeeded, let crashed = remaining.first else { break }
      // The worker died on this set, most likely in a plugin. Record it and
      // carry on with the rest.
      results.append(BatchSetResult(
        set: crashed.set, outcome: .failed("the conversion process stopped unexpectedly on this set")))
      remaining = remaining.dropFirst()
    }
    currentStep = ""
    isFinished = true
  }

  /// Returns whether the worker exited cleanly.
  private func runWorker(for jobs: [BatchJob]) async -> Bool {
    let folder: URL?
    if case .folder(let url) = destination { folder = url } else { folder = nil }
    guard let executable = Bundle.main.executableURL,
          let request = try? JSONEncoder().encode(BatchWorkerRequest(jobs: jobs, folder: folder)) else {
      return false
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--batch-worker"]
    process.qualityOfService = .userInitiated
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    worker = process
    input.fileHandleForWriting.write(request)
    try? input.fileHandleForWriting.close()

    let decoder = JSONDecoder()
    do {
      for try await line in output.fileHandleForReading.bytes.lines {
        guard line.hasPrefix(BatchWorkerEvent.linePrefix),
              let event = try? decoder.decode(
                BatchWorkerEvent.self, from: Data(line.dropFirst(BatchWorkerEvent.linePrefix.count).utf8))
        else { continue }
        switch event {
        case .step(let text): currentStep = text
        case .result(let result): results.append(result)
        }
      }
    } catch {}
    process.waitUntilExit()
    worker = nil
    return process.terminationStatus == 0 && process.terminationReason == .exit
  }
}
