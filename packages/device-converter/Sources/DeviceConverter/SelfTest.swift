import Foundation

/// Headless verification of the parse → convert → save → re-parse pipeline,
/// used because the GUI can't be driven in CI. Run with `--selftest <file.als>`.
enum SelfTest {
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
      let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("selftest-\(UUID().uuidString).als")
      try out.write(to: tmp)
      let doc2 = try AlsDocument(url: tmp)
      let devices2 = DeviceExtractor.extractAll(doc2.root)
      try? FileManager.default.removeItem(at: tmp)

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
