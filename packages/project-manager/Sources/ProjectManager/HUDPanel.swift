import AppKit
import SwiftUI

/// A floating HUD panel for a table row's details, opened by double-clicking the
/// row. There's one: showing other details replaces what it shows. Escape or
/// switching apps closes it.
@MainActor
final class HUDPanel {
  static let shared = HUDPanel()
  private var panel: NSPanel?

  func show(title: String, @ViewBuilder content: () -> some View) {
    let panel = self.panel ?? Self.makePanel()
    self.panel = panel
    panel.title = title
    panel.contentView = NSHostingView(rootView: content().frame(minWidth: 260, minHeight: 160))
    if !panel.isVisible { Self.placeNearPointer(panel) }
    panel.makeKeyAndOrderFront(nil)
  }

  func close() { panel?.orderOut(nil) }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
      styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow],
      backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = true
    panel.isReleasedWhenClosed = false
    return panel
  }

  /// Beside the pointer (where the row was double-clicked), kept on its screen.
  private static func placeNearPointer(_ panel: NSPanel) {
    let pointer = NSEvent.mouseLocation
    let size = panel.frame.size
    var origin = NSPoint(x: pointer.x + 16, y: pointer.y - size.height / 2)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame {
      origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
      origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
    }
    panel.setFrameOrigin(origin)
  }
}
