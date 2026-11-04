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
    let catalog = Vst3Catalog.installed()
    print("\(root): \(projects.count) projects, \(sets.count) sets, \(catalog.count) VST3 classes")

    var counts: [SetStatus.Kind: Int] = [:]
    var mismatches = 0, unreadable = 0
    var scanTime = 0.0, domTime = 0.0
    for set in sets {
      do {
        var t = Date()
        let scan = try LiveSetScanner.scan(url: set.url)
        scanTime += Date().timeIntervalSince(t)
        let converted = set.convertedURL.flatMap { try? LiveSetScanner.scan(url: $0) }
        counts[SetStatus.resolve(
          scan: scan, convertedScan: converted, hasConversion: set.convertedURL != nil,
          catalog: catalog, catalogLoading: false).kind, default: 0] += 1

        t = Date()
        let doc = try AlsDocument(url: set.url)
        let devices = DeviceExtractor.extractAll(doc.root)
        domTime += Date().timeIntervalSince(t)
        let fromDom = devices.filter { $0.format == .vst }.map(\.product).sorted()
        let fromScan = scan.vst2.map(\.name).sorted()
        let chunkDom = devices.filter { $0.format == .vst && Vst2State.isChunkPreset($0.element) }.count
        if fromDom != fromScan || chunkDom != scan.vst2.filter(\.isChunk).count
          || scan.creator != doc.creator
          || devices.filter({ $0.format == .vst3 }).count != scan.vst3Count
          || devices.filter({ $0.format == .au }).count != scan.auCount {
          mismatches += 1
          print("  ✗ \(set.url.lastPathComponent): scan \(fromScan.count) vst2/\(scan.vst3Count) vst3/\(scan.auCount) au"
            + " vs DOM \(fromDom.count)/\(devices.filter { $0.format == .vst3 }.count)/\(devices.filter { $0.format == .au }.count)")
        }
      } catch {
        unreadable += 1
        print("  ✗ \(set.url.lastPathComponent): \(error)")
      }
    }
    for kind in SetStatus.Kind.allCases where counts[kind] != nil {
      print("  \(kind.title): \(counts[kind]!)")
    }
    print(String(format: "scan %.1fs, DOM %.1fs; %d mismatches, %d unreadable",
                 scanTime, domTime, mismatches, unreadable))
    return mismatches == 0 ? 0 : 1
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
