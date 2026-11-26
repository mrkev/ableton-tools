// Draws the app icon and writes App/AppIcon.icns. Run from the package folder:
//
//     swift App/make-icon.swift
//
// A rounded square in a blue-violet gradient with the swap symbol in white.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
// macOS icons keep a margin around the rounded square.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [NSColor(srgbRed: 0.32, green: 0.36, blue: 0.95, alpha: 1),
                    NSColor(srgbRed: 0.62, green: 0.30, blue: 0.86, alpha: 1)])!
  .draw(in: shape, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
  .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)?
  .withSymbolConfiguration(config) {
  let s = symbol.size
  symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let px = base * scale
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
  }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "App/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote App/AppIcon.icns" : "iconutil failed")
