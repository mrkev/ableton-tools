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
enum ProjectManagerApp {
  @MainActor static func main() {
    LegacyMigration.run()
    // Headless verification path (no GUI): --selftest <file.als>
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
      SelfTest.run(path: args[i + 1])
      exitSkippingPluginTeardown(0)
    }
    // Headless VST2 → VST3 migration: --vst3 <file.als> [--out <out.als>]
    if args.contains("--vst3") {
      Task { @MainActor in exitSkippingPluginTeardown(await Vst3Cli.run(arguments: args)) }
      RunLoop.main.run()
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
    // Debugging aid: how a VST3 stores its state.
    if args.contains("--probe-vst3") {
      exitSkippingPluginTeardown(ProbeCli.run(arguments: args))
    }
    // Headless check of a set page's plan (and its save).
    if args.contains("--selftest-plan") {
      Task { @MainActor in exitSkippingPluginTeardown(await SelfTest.runPlan(arguments: args)) }
      RunLoop.main.run()
    }
    // Headless check of library discovery and scanning.
    if let i = args.firstIndex(of: "--selftest-library"), i + 1 < args.count {
      exitSkippingPluginTeardown(SelfTest.runLibrary(path: args[i + 1]))
    }

    let model = AppModel()
    // `ProjectManager <folder>` opens a folder of projects, or one project, on launch.
    // Arguments that follow an option are its value, not a path.
    let valued: Set<String> = ["--select"]
    let paths = args.indices.dropFirst().filter { !args[$0].hasPrefix("-") && !valued.contains(args[$0 - 1]) }
    if let i = paths.first {
      model.open(url: URL(fileURLWithPath: args[i]))
    }
    // For screenshots and debugging: --select overview|plugins|<set or project path>.
    if let i = args.firstIndex(of: "--select"), i + 1 < args.count {
      switch args[i + 1] {
      case "overview": model.selection = [.overview]
      case "plugins": model.selection = [.plugins]
      case let path where path.hasSuffix(".als"): model.reveal(URL(fileURLWithPath: path))
      case let path: model.selection = [.project(URL(fileURLWithPath: path))]
      }
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
  private var settingsWindow: NSWindow?

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
    // Named in the Window menu and Mission Control; each page has its own heading.
    window.title = "Ableton Project Manager"
    window.titleVisibility = .hidden
    window.center()
    window.setFrameAutosaveName("MainWindow")
    window.contentView = NSHostingView(rootView: root)
    window.makeKeyAndOrderFront(nil)
    buildMenu()
    if CommandLine.arguments.contains("--settings") { showSettings() }
    // DC_BACKGROUND=1 leaves the frontmost app frontmost (for scripted screenshots).
    if ProcessInfo.processInfo.environment["DC_BACKGROUND"] == nil { NSApp.activate(ignoringOtherApps: true) }
  }

  func applicationWillTerminate(_ notification: Notification) { exitSkippingPluginTeardown(0) }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// A folder from Finder ("Open With", or dropped on the Dock icon).
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    model.open(url: url)
    window?.makeKeyAndOrderFront(nil)
  }

  @objc func openDocument() { model.presentOpenPanel() }
  @objc func saveDocument() { model.activeModel?.presentSavePanel() }
  @objc func rescanLibrary() { model.rescan() }
  @objc func fixInBulk() {
    let scope = model.batchScope
    model.presentBatch(for: scope.sets, title: scope.title)
  }
  @objc func openInLive() { focusedSetChoices?.open() }
  @objc func openInChosenLive(_ sender: NSMenuItem) {
    guard let live = sender.representedObject as? LiveApp else { return }
    focusedSetChoices?.open(in: live)
  }

  /// How the set on screen can be opened; nil when no set is.
  private var focusedSetChoices: OpenChoices? {
    guard let url = focusedURL, url.pathExtension.lowercased() == "als" else { return nil }
    return OpenChoices(url: url, app: model)
  }
  @objc func showInFinder() { focusedURL.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }

  /// The set, or else the project, on screen.
  private var focusedURL: URL? {
    if let url = model.focusedSetURL { return url }
    if case .project(let url)? = model.focus { return url }
    return nil
  }

  @objc func showSettings() {
    if settingsWindow == nil {
      let view = SettingsView().environmentObject(model).environmentObject(model.catalogs)
      let window = NSWindow(contentViewController: NSHostingController(rootView: view))
      window.title = "Settings"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  private func buildMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About Ableton Project Manager", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Ableton Project Manager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(
      withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    let open = fileMenu.addItem(
      withTitle: "Open…", action: #selector(openDocument), keyEquivalent: "o")
    open.target = self
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: "Fix and Save Copy…", action: #selector(saveDocument), keyEquivalent: "s")
      .target = self
    fileMenu.addItem(withTitle: "Fix Sets in Bulk…", action: #selector(fixInBulk), keyEquivalent: "")
      .target = self
    fileMenu.addItem(.separator())
    // Titled for the set on screen ("Open in Live 10") as the menu opens.
    fileMenu.addItem(withTitle: "Open in Live", action: #selector(openInLive), keyEquivalent: "l")
      .target = self
    let openIn = fileMenu.addItem(withTitle: "Open In", action: nil, keyEquivalent: "")
    openIn.submenu = NSMenu(title: "Open In")
    openIn.submenu?.delegate = self
    let finder = fileMenu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "r")
    finder.keyEquivalentModifierMask = [.command, .shift]
    finder.target = self
    fileMenu.addItem(.separator())
    let rescan = fileMenu.addItem(
      withTitle: "Rescan", action: #selector(rescanLibrary), keyEquivalent: "r")
    rescan.target = self
    fileItem.submenu = fileMenu

    // Text fields (the search field) need these to cut, copy and paste.
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }
}

extension AppDelegate: NSMenuItemValidation, NSMenuDelegate {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(openInLive):
      let choices = focusedSetChoices
      item.title = choices?.title ?? "Open in Live"
      return choices.map { !$0.tooNew } ?? false
    case #selector(openInChosenLive(_:)):
      return true
    default:
      return true
    }
  }

  /// File › Open In: every installed Live, with those too old for the set greyed out.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let choices = focusedSetChoices
    let usable = choices.map { Set([$0.preferred].compactMap { $0 } + $0.later) } ?? []
    for live in LiveApps.installed.reversed() {
      let item = NSMenuItem(title: live.name, action: nil, keyEquivalent: "")
      item.toolTip = live.url.path
      if #available(macOS 14.4, *) { item.subtitle = live.detail }
      if usable.contains(live) {
        item.action = #selector(openInChosenLive(_:))
        item.target = self
        item.representedObject = live
        if live == choices?.preferred { item.state = .on }
      }
      menu.addItem(item)
    }
    if LiveApps.installed.isEmpty {
      menu.addItem(withTitle: "No Live Installed", action: nil, keyEquivalent: "")
    }
  }
}
