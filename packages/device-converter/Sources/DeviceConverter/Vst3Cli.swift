import Foundation

/// Headless VST2 → VST3 migration of one Live Set:
///
///     DeviceConverter --vst3 <in.als> [--out <out.als>] [--dry-run] [--verbose] [--force]
///
/// Converts every VST2 device that has an installed (and natively loadable)
/// VST3 replacement, writes a new set (default: `<name>-vst3.als` beside the
/// original — the original is never touched) and prints a per-device report.
enum Vst3Cli {
  static func run(arguments args: [String]) -> Int32 {
    guard let i = args.firstIndex(of: "--vst3"), i + 1 < args.count else {
      print("usage: DeviceConverter --vst3 <in.als> [--out <out.als>] [--dry-run] [--verbose] [--force]")
      return 2
    }
    let input = URL(fileURLWithPath: args[i + 1])
    let output = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
      ?? input.deletingLastPathComponent()
        .appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-vst3.als")
    let dryRun = args.contains("--dry-run")
    let verbose = args.contains("--verbose")

    do {
      let doc = try AlsDocument(url: input)
      // VST3 support (and the block layout we write) arrived in Live 10.
      let creator = doc.root.attribute(forName: "Creator")?.stringValue ?? ""
      if let major = creator.split(separator: " ").last?.split(separator: ".").first.flatMap({ Int($0) }),
         major < 10, !args.contains("--force") {
        print("\(input.lastPathComponent): saved by \(creator), which predates VST3 in Live."
          + " Open and re-save it in Live 10+ first, or pass --force.")
        return 3
      }
      let devices = DeviceExtractor.extractAll(doc.root)
      let catalog = Vst3Catalog.installed()
      let automated = Set((try? doc.root.nodes(forXPath: "//PointeeId/@Value"))?.compactMap(\.stringValue) ?? [])
      print("\(input.lastPathComponent): \(devices.count) devices; \(catalog.count) loadable VST3 classes installed")

      var converted = 0, skipped = 0
      for d in devices where d.format == .vst {
        let label = "\(d.trackName) › \(d.name)"
        guard let target = Vst3Migration.target(for: d, in: catalog) else {
          print("  – \(label): no installed native VST3"); skipped += 1; continue
        }
        do {
          let c = try Vst3Migration.prepare(d, target: target, automatedTargets: automated)
          print("  ✓ \(label) → \(target.name) VST3 · state \(c.processorState.count) B"
            + " · \(c.changedFromDefault)/\(c.parameterCount) params off default"
            + " · \(c.parameterMap.count) mapped slot(s)")
          if verbose { for m in c.mapping { print("      \(m)") } }
          for w in c.warnings { print("      ⚠︎ \(w)") }
          let replacement = DeviceBuilder.makeVst3Device(from: d, conversion: c)
          d.parent.replaceChild(at: d.element.index, with: replacement)
          converted += 1
        } catch {
          print("  ✗ \(label): \(error)"); skipped += 1
        }
      }
      print("converted \(converted), skipped \(skipped)")
      guard converted > 0, !dryRun else { return 0 }

      try doc.save(to: output)
      // Prove the result re-parses with the same device layout.
      let after = DeviceExtractor.extractAll(try AlsDocument(url: output).root)
      let vst3 = after.filter { $0.format == .vst3 }.count
      print("wrote \(output.path) — re-parsed \(after.count) devices (\(vst3) VST3)"
        + (after.count == devices.count ? "" : " ✗ device count changed!"))
      return 0
    } catch {
      print("error: \(error)")
      return 1
    }
  }
}
