import AppKit
import SwiftUI

/// Exits without running exit-time destructors. Loaded plugins stay in the process,
/// and some crash tearing themselves down (Massive's Qt application does), which
/// would lose buffered output and report a failure after the work has succeeded.
func exitSkippingPluginTeardown(_ code: Int32) -> Never {
  fflush(stdout)
  fflush(stderr)
  _exit(code)
}

@main
enum DeviceConverterApp {
  @MainActor static func main() {
    // Headless verification path (no GUI): --selftest <file.als>
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
      SelfTest.run(path: args[i + 1])
      exitSkippingPluginTeardown(0)
    }
    // Headless VST2 → VST3 migration: --vst3 <file.als> [--out <out.als>]
    if args.contains("--vst3") {
      exitSkippingPluginTeardown(Vst3Cli.run(arguments: args))
    }

    // A batch started from the GUI runs here, in a child process.
    if args.contains("--batch-worker") {
      Task { @MainActor in exitSkippingPluginTeardown(await BatchWorker.run()) }
      RunLoop.main.run()
    }
    // Headless batch conversion: --batch <folder> --out-dir <dir>
    if args.contains("--batch") {
      Task { @MainActor in exitSkippingPluginTeardown(await BatchCli.run(arguments: args)) }
      RunLoop.main.run()
    }
    // Headless check of library discovery and scanning.
    if let i = args.firstIndex(of: "--selftest-library"), i + 1 < args.count {
      exitSkippingPluginTeardown(SelfTest.runLibrary(path: args[i + 1]))
    }

    let model = AppModel()
    // `DeviceConverter <path>` opens a library, project folder or set on launch.
    if let path = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
      model.open(url: URL(fileURLWithPath: path))
    }
    let application = NSApplication.shared
    // NSApplication.delegate is weak; the local binding keeps it alive because
    // run() blocks until the app quits.
    let delegate = AppDelegate(model: model)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model: AppModel
  var window: NSWindow!

  init(model: AppModel) {
    self.model = model
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let root = RootView().environmentObject(model).environmentObject(model.catalogs)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Device Converter"
    window.center()
    window.setFrameAutosaveName("MainWindow")
    window.contentView = NSHostingView(rootView: root)
    window.makeKeyAndOrderFront(nil)
    buildMenu()
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationWillTerminate(_ notification: Notification) { exitSkippingPluginTeardown(0) }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  @objc func openDocument() { model.presentOpenPanel() }
  @objc func saveDocument() { model.activeModel?.presentSavePanel() }
  @objc func rescanLibrary() { model.rescan() }

  private func buildMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    let open = fileMenu.addItem(
      withTitle: "Open…", action: #selector(openDocument), keyEquivalent: "o")
    open.target = self
    let save = fileMenu.addItem(
      withTitle: "Save As…", action: #selector(saveDocument), keyEquivalent: "s")
    save.target = self
    fileMenu.addItem(.separator())
    let rescan = fileMenu.addItem(
      withTitle: "Rescan", action: #selector(rescanLibrary), keyEquivalent: "r")
    rescan.target = self
    fileItem.submenu = fileMenu

    NSApp.mainMenu = mainMenu
  }
}
