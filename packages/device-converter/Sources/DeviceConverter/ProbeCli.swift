import Foundation

/// `--probe-vst3 <bundle.vst3> [--state <file>]`: a debugging aid for working out
/// how a VST3 stores its state. Lists its classes; for each audio module prints
/// its parameters and own state, then, with `--state`, loads that file and prints
/// which parameters moved and the state the plugin writes back.
enum ProbeCli {
  @MainActor static func run(arguments args: [String]) -> Int32 {
    setlinebuf(stdout)
    guard let i = args.firstIndex(of: "--probe-vst3"), i + 1 < args.count else {
      print("usage: DeviceConverter --probe-vst3 <bundle.vst3> [--state <file>]")
      return 2
    }
    let bundle = URL(fileURLWithPath: args[i + 1])
    let state = args.firstIndex(of: "--state").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
      .flatMap { FileManager.default.contents(atPath: $0) }
    let classes = Vst3Catalog.classes(in: bundle)
    guard !classes.isEmpty else {
      print("no audio module classes in \(bundle.path) (not native, or not a VST3)")
      return 1
    }
    for info in classes {
      print("class '\(info.name)' cid \(hex(Data(info.cid))) (\(printable(Data(info.cid))))")
      do {
        let plugin = try Vst3Instance(info)
        let defaults = plugin.parameters
        print("  \(defaults.count) parameters")
        for p in defaults { print(String(format: "    %10u  %-28@ %.6f", p.id, p.title as NSString, p.normalized)) }
        dump("  own component state", plugin.componentState())
        dump("  own controller state", plugin.controllerState())
        guard let state else { continue }
        do {
          try plugin.setState(state)
          print("  loaded \(state.count) bytes")
        } catch {
          print("  setState: \(error)")
          continue
        }
        let before = Dictionary(defaults.map { ($0.id, $0.normalized) }, uniquingKeysWith: { a, _ in a })
        let moved = plugin.parameters.filter { abs((before[$0.id] ?? $0.normalized) - $0.normalized) > 1e-6 }
        print("  \(moved.count) parameters moved")
        for p in moved {
          print(String(format: "    %10u  %-28@ %.6f → %.6f", p.id, p.title as NSString, before[p.id] ?? 0, p.normalized))
        }
        dump("  component state after", plugin.componentState())
      } catch {
        print("  \(error)")
      }
    }
    return 0
  }

  private static func dump(_ label: String, _ data: Data?) {
    guard let data else { return print("\(label): none") }
    print("\(label): \(data.count) bytes")
    for start in stride(from: 0, to: min(data.count, 512), by: 32) {
      let chunk = data[data.startIndex + start..<data.startIndex + min(start + 32, data.count)]
      print("    \(hex(chunk))  \(printable(chunk))")
    }
    if data.count > 512 { print("    …") }
  }

  private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

  private static func printable(_ d: Data) -> String {
    String(d.map { (0x20..<0x7f).contains($0) ? Character(UnicodeScalar($0)) : "." })
  }
}
