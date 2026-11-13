import Foundation

/// Headless VST2 → VST3 migration of one Live Set (plus Intel-only AUs built
/// around a VST2 whose VST3 replaces them):
///
///     DeviceConverter --vst3 <in.als> [--out <out.als>] [--substitute-orbit] [--substitute-pro-c]
///                     [--dry-run] [--verbose] [--force]
///
/// Converts every VST2 device that has an installed (and natively loadable)
/// VST3 replacement, writes a new set (default: `<name>-vst3.als` beside the
/// original — the original is never touched) and prints a per-device report.
/// `--substitute-orbit` also replaces AMBEO Orbit with dearVR MICRO, and
/// `--substitute-pro-c` FabFilter Pro-C with Pro-C 2.
enum Vst3Cli {
  @MainActor static func run(arguments args: [String]) async -> Int32 {
    setlinebuf(stdout)
    guard let i = args.firstIndex(of: "--vst3"), i + 1 < args.count else {
      print("usage: DeviceConverter --vst3 <in.als> [--out <out.als>] "
        + Substitution.allCases.map { "[\($0.cliFlag)] " }.joined() + "[--dry-run] [--verbose] [--force]")
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
      if doc.predatesVst3, !args.contains("--force") {
        print("\(input.lastPathComponent): saved by \(doc.creator), which predates VST3 in Live."
          + " Open and re-save it in Live 10+ first, or pass --force.")
        return 3
      }
      let devices = DeviceExtractor.extractAll(doc.root)
      var inventory = PluginInventory.loadNow()
      inventory.substitutions = Substitution.optedIn(arguments: args)
      let catalog = inventory.vst3
      let automated = doc.automatedTargetIds
      print("\(input.lastPathComponent): \(devices.count) devices; \(catalog.count) loadable VST3 classes installed")

      var converted = 0, skipped = 0
      for d in devices where d.format == .vst || d.format == .au || Substitution.matching(d) != nil {
        let label = "\(d.trackName) › \(d.name)"
        if let (sub, target) = inventory.substitution(for: d) {
          do {
            let c = try await sub.convert(d, target: target, document: doc, automatedTargets: automated)
            c.apply(replacing: d)
            print("  ✓ \(label) → \(sub.targetName) \(target.badge) · \(c.detail)")
            for n in c.notes { print("      ⚠︎ \(n)") }
            converted += 1
          } catch {
            print("  ✗ \(label): \(error)"); skipped += 1
          }
          continue
        }
        if let sub = Substitution.matching(d) {
          print("  – \(label): \(sub.sourceName); pass \(sub.cliFlag) to replace it with \(sub.targetName)")
          skipped += 1
          continue
        }
        let target: Vst3PluginInfo
        if let au = LiveSetScan.AuPlugin(device: d) {
          // Only AUs that need it; most have no VST3 counterpart at all.
          guard case .needsConversion(let t) = inventory.load(au) else { continue }
          target = t
        } else if let t = Vst3Migration.target(for: d, in: catalog) {
          target = t
        } else {
          print("  – \(label): no installed native VST2-compatible VST3"); skipped += 1; continue
        }
        do {
          let c = try Vst3Migration.prepare(d, target: target, automatedTargets: automated)
          print("  ✓ \(label) (\(d.format.badge ?? "")) → \(target.name) VST3 · state \(c.processorState.count) B"
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
      let added = after.count - devices.count
      print("wrote \(output.path) — re-parsed \(after.count) devices (\(vst3) VST3, \(added) added)")
      return 0
    } catch {
      print("error: \(error)")
      return 1
    }
  }
}
