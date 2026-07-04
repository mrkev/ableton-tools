import AppKit
import SwiftUI

@main
enum DeviceConverterApp {
  @MainActor static func main() {
    // Headless verification path (no GUI): --selftest <file.als>
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
      SelfTest.run(path: args[i + 1])
      return
    }

    let model = ConverterModel()
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
  let model: ConverterModel
  var window: NSWindow!

  init(model: ConverterModel) {
    self.model = model
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let root = ContentView().environmentObject(model)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Ableton Device Converter"
    window.center()
    window.setFrameAutosaveName("MainWindow")
    window.contentView = NSHostingView(rootView: root)
    window.makeKeyAndOrderFront(nil)
    buildMenu()
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  @objc func openDocument() { model.presentOpenPanel() }
  @objc func saveDocument() { model.presentSavePanel() }

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
    fileItem.submenu = fileMenu

    NSApp.mainMenu = mainMenu
  }
}
