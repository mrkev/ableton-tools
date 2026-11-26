import Foundation

/// Headless verification of the parse → convert → save → re-parse pipeline,
/// used because the GUI can't be driven in CI. Run with `--selftest <file.als>`.
enum SelfTest {
  /// Discover a folder, scan every set, and check the fast scanner against the
  /// DOM extractor (the code that actually converts). Returns a process exit code.
  static func runLibrary(path: String) -> Int32 {
    let url = URL(fileURLWithPath: path)
    guard let root = LibraryDiscovery.classify(url) else {
      print("no Live Sets in \(path)")
      return 1
    }
    let projects = LibraryDiscovery.projects(for: root)
    let sets = projects.flatMap(\.sets)
    var inventory = PluginInventory.loadNow()
    // Opt-ins as the batch takes them (--substitute-orbit, --substitute-pro-c).
    inventory.substitutions = Substitution.optedIn(arguments: CommandLine.arguments)
    print("\(root): \(projects.count) projects, \(sets.count) sets, \(inventory.vst3.count) VST3 classes")

    var counts: [SetStatus.Kind: Int] = [:]
    var stuckSets: [String: Set<URL>] = [:]
    var reasons: [String: String] = [:]
    var mismatches = 0, unreadable = 0
    var scanTime = 0.0, domTime = 0.0
    let locations = LiveLocations.current()
    let index = SampleIndex.build(locations)
    var namesakes = 0
    let listMissing = CommandLine.arguments.contains("--list-missing")
    var setsMissing = 0, filesMissing = 0, freezeMissing = 0, noTempo = 0
    var opensIn: [String: Int] = [:]
    for set in sets {
      do {
        var t = Date()
        let scan = try LiveSetScanner.scan(url: set.url)
        scanTime += Date().timeIntervalSince(t)
        let converted = set.convertedURL.flatMap { try? LiveSetScanner.scan(url: $0) }
        let status = SetStatus.resolve(
          scan: scan, convertedScan: converted, hasConversion: set.convertedURL != nil, inventory: inventory)
        counts[status.kind, default: 0] += 1
        let missing = locations.missing(in: scan, setURL: set.url, index: index)
        let real = missing.filter { !$0.isFreeze }
        if !real.isEmpty { setsMissing += 1 }
        filesMissing += real.count
        namesakes += real.filter(\.hasNamesake).count
        freezeMissing += missing.count - real.count
        if scan.tempo == nil { noTempo += 1 }
        let preferred = LiveApps.preferred(forCreator: scan.creator)
        let later = LiveApps.compatible(withCreator: scan.creator).filter { $0 != preferred }.map(\.name)
        opensIn[(preferred?.name ?? "no Live") + (later.isEmpty ? "" : " (or \(later.joined(separator: ", ")))"), default: 0] += 1
        if listMissing && !real.isEmpty {
          print("  \(set.url.lastPathComponent): \(scan.samples.count) samples, \(real.count) missing")
          for m in real.prefix(5) { print("    \(m.hasNamesake ? "≈ " : "")\(m.lastKnown)") }
        }
        if case .stuck(let plugins, _) = status {
          for p in plugins {
            stuckSets[p.name, default: []].insert(set.url)
            reasons[p.name] = p.reason
          }
        }

        t = Date()
        let doc = try AlsDocument(url: set.url)
        let devices = DeviceExtractor.extractAll(doc.root)
        domTime += Date().timeIntervalSince(t)
        func names(_ format: DeviceFormat) -> [String] {
          devices.filter { $0.format == format }.map(\.product).sorted()
        }
        let chunkDom = devices.filter { $0.format == .vst && Vst2State.isChunkPreset($0.element) }.count
        let uidsDom = devices.compactMap(\.vst3Uid).map { $0.map(String.init).joined(separator: ",") }.sorted()
        let uidsScan = scan.vst3.map { $0.uid.map(String.init).joined(separator: ",") }.sorted()
        let auDom = devices.filter { $0.format == .au }.map { "\($0.auType ?? "")/\($0.auSubType ?? "")/\($0.auManufacturer ?? "")" }.sorted()
        let auScan = scan.au.map { p in
          [p.type, p.subType, p.manufacturer].map { DeviceExtractor.fourCC(Int($0)) ?? "" }.joined(separator: "/")
        }.sorted()
        if names(.vst) != scan.vst2.map(\.name).sorted() || chunkDom != scan.vst2.filter(\.isChunk).count
          || names(.vst3) != scan.vst3.map(\.name).sorted() || uidsDom != uidsScan
          || names(.au) != scan.au.map(\.name).sorted() || auDom != auScan
          || scan.creator != doc.creator {
          mismatches += 1
          print("  ✗ \(set.url.lastPathComponent): scan \(scan.vst2.count)/\(scan.vst3.count)/\(scan.au.count)"
            + " vs DOM \(names(.vst).count)/\(names(.vst3).count)/\(names(.au).count)")
        }
      } catch {
        unreadable += 1
        print("  ✗ \(set.url.lastPathComponent): \(error)")
      }
    }
    for kind in SetStatus.Kind.allCases where counts[kind] != nil {
      print("  \(kind.title): \(counts[kind]!)")
    }
    for (name, urls) in stuckSets.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) {
      print("  stuck: \(urls.count) sets on \(name) (\(reasons[name] ?? ""))")
    }
    print("  Live installed: " + LiveApps.installed.map { "\($0.name) (\($0.detail))" }.joined(separator: ", "))
    for (live, count) in opensIn.sorted(by: { $0.key < $1.key }) { print("  opens in \(live): \(count)") }
    print("  missing samples: \(filesMissing) in \(setsMissing) sets (\(namesakes) have a namesake in the library; +\(freezeMissing) freeze files); \(noTempo) sets without a tempo")
    print(String(format: "scan %.1fs, DOM %.1fs; %d mismatches, %d unreadable",
                 scanTime, domTime, mismatches, unreadable))
    return mismatches == 0 ? 0 : 1
  }

  /// The plan a set page shows, and optionally the fixed copy it saves:
  /// `--selftest-plan <set.als> [--replace] [--out <copy.als>]`. `--replace` picks
  /// every available replacement, as the page's menus would.
  @MainActor static func runPlan(arguments args: [String]) async -> Int32 {
    guard let i = args.firstIndex(of: "--selftest-plan"), i + 1 < args.count else { return 2 }
    let catalogs = PluginCatalogs()
    while catalogs.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
    let model = SetModel(url: URL(fileURLWithPath: args[i + 1]), catalogs: catalogs)
    await model.loadIfNeeded()
    if let error = model.loadError {
      print("couldn't open: \(error)")
      return 1
    }
    print("defaults: replace \(catalogs.substitutions.map(\.sourceName).sorted())")
    if args.contains("--replace") {
      for group in model.groups {
        if let (sub, target) = catalogs.substitution(for: group.devices[0]) {
          model.setAction(.substitute(sub, target), for: group)
        }
      }
    }
    for group in model.groups {
      let load = model.load(of: group.devices[0]).map { "\($0)" } ?? "-"
      let action = model.action(for: group)
      print("  \(model.willLoad(group) ? "✓" : "✗") \(group.format.rawValue) \(group.name) ×\(group.devices.count): "
        + "\(load.prefix(60)) → \(String(describing: action).prefix(80))")
    }
    print("changing \(model.changingGroups.count), broken \(model.brokenGroups.map(\.name)), canFix \(model.canFix)")
    guard let o = args.firstIndex(of: "--out"), o + 1 < args.count else { return 0 }
    model.save(to: URL(fileURLWithPath: args[o + 1]))
    while model.isSaving { try? await Task.sleep(for: .milliseconds(100)) }
    print(model.status ?? "no status")
    model.report.forEach { print("  \($0)") }
    print("after save: changing \(model.changingGroups.count), broken \(model.brokenGroups.map(\.name))")
    return 0
  }

  static func run(path: String) {
    do {
      let url = URL(fileURLWithPath: path)
      let doc = try AlsDocument(url: url)
      let devices = DeviceExtractor.extractAll(doc.root)
      print("opened \(url.lastPathComponent): \(devices.count) devices")
      for d in devices where d.format != .native {
        print("  \(d.format.rawValue) \(d.category.rawValue) '\(d.name)'")
      }

      // Best-effort AU discovery (may be empty in a sandbox).
      let catalog = AudioUnitCatalog.installed()
      print("installed AUs: \(catalog.count)")

      guard let source = devices.first(where: { $0.format == .vst3 || $0.format == .vst }) else {
        print("no VST device to convert; done."); return
      }

      // Prefer a real installed AU match; otherwise synthesize a target so the
      // replacement mechanism is still exercised deterministically.
      let target = catalog.first { $0.name.lowercased().contains(source.product.lowercased()) }
        ?? AudioUnitInfo(
          name: source.product, manufacturer: "Test Vendor",
          typeCode: AudioUnitCatalog.code(fromFourCC: source.category == .instrument ? "aumu" : "aufx"),
          subTypeCode: AudioUnitCatalog.code(fromFourCC: "Tst1"),
          manufacturerCode: AudioUnitCatalog.code(fromFourCC: "TstV"))
      print("converting '\(source.name)' (\(source.format.rawValue)) → AU '\(target.name)'"
        + " [\(target.typeFourCC)/\(target.subTypeFourCC)/\(target.manufacturerFourCC)]")

      // Apply the replacement in the DOM.
      let idx = source.element.index
      let newEl = DeviceBuilder.makeAUDevice(from: source, target: target)
      source.parent.replaceChild(at: idx, with: newEl)

      // Serialize, then re-open from bytes to prove it's valid + intact.
      let out = try doc.serialized()
      let outPath = CommandLine.arguments.firstIndex(of: "--out").map {
        URL(fileURLWithPath: CommandLine.arguments[$0 + 1])
      }
      let tmp = outPath ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("selftest-\(UUID().uuidString).als")
      try out.write(to: tmp)
      let doc2 = try AlsDocument(url: tmp)
      let devices2 = DeviceExtractor.extractAll(doc2.root)
      if outPath == nil { try? FileManager.default.removeItem(at: tmp) }
      else { print("wrote \(tmp.path)") }

      let sameCount = devices2.count == devices.count
      let converted = devices2.first { $0.type == "AuPluginDevice" && $0.name == target.name }
      print("re-parsed: \(devices2.count) devices (count preserved: \(sameCount))")
      if let c = converted {
        print("✓ converted device present: <\(c.type)> '\(c.name)'"
          + " au=\(c.auType ?? "?")/\(c.auSubType ?? "?")/\(c.auManufacturer ?? "?")"
          + " category=\(c.category.rawValue)")
      } else {
        print("✗ converted AU device not found after re-parse")
      }
    } catch {
      print("selftest error: \(error)")
    }
  }
}
