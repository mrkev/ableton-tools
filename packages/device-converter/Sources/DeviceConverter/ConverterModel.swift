import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// What a slot on the right-hand column resolves to.
enum SlotAction: Equatable {
  case keep
  case replaceAU(AudioUnitInfo)
}

@MainActor
final class ConverterModel: ObservableObject {
  @Published private(set) var document: AlsDocument?
  @Published private(set) var devices: [Device] = []
  @Published private(set) var catalog: [AudioUnitInfo] = []
  /// Per-device slot decision, keyed by device id.
  @Published var actions: [UUID: SlotAction] = [:]
  @Published var status: String = "Open an .als file to begin."
  @Published var isLoadingCatalog = true

  var fileName: String { document?.sourceURL.lastPathComponent ?? "No file" }
  var hasChanges: Bool { actions.values.contains { $0 != .keep } }

  init() {
    loadCatalog()
  }

  // MARK: Panels

  private var alsType: UTType { UTType(filenameExtension: "als") ?? .data }

  func presentOpenPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [alsType]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { open(url: url) }
  }

  func presentSavePanel() {
    guard let document else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [alsType]
    let base = document.sourceURL.deletingPathExtension().lastPathComponent
    panel.nameFieldStringValue = "\(base)-converted.als"
    if panel.runModal() == .OK, let url = panel.url { save(to: url) }
  }

  // MARK: Loading

  func open(url: URL) {
    do {
      let doc = try AlsDocument(url: url)
      let found = DeviceExtractor.extractAll(doc.root)
      document = doc
      devices = found
      actions = Dictionary(uniqueKeysWithValues: found.map { ($0.id, .keep) })
      let plugins = found.filter { $0.format != .native }.count
      status = "\(found.count) devices · \(plugins) plugins"
    } catch {
      status = "Couldn't open: \(error)"
    }
  }

  private func loadCatalog() {
    Task.detached(priority: .userInitiated) {
      let units = AudioUnitCatalog.installed()
      await MainActor.run {
        self.catalog = units
        self.isLoadingCatalog = false
      }
    }
  }

  // MARK: Slots

  func action(for device: Device) -> SlotAction { actions[device.id] ?? .keep }

  func setAction(_ action: SlotAction, for device: Device) {
    actions[device.id] = action
  }

  /// The installed AU whose name best matches this device (for auto-suggest).
  func suggestedAU(for device: Device) -> AudioUnitInfo? {
    let want = device.product.lowercased()
    guard !want.isEmpty else { return nil }
    // Prefer an exact name match; fall back to contains.
    if let exact = catalog.first(where: { $0.name.lowercased() == want }) {
      return exact
    }
    return catalog.first { $0.name.lowercased().contains(want) || want.contains($0.name.lowercased()) }
  }

  /// Auto-convert one device to its suggested AU (structural swap).
  @discardableResult
  func autoConvert(_ device: Device) -> Bool {
    guard let au = suggestedAU(for: device) else { return false }
    setAction(.replaceAU(au), for: device)
    return true
  }

  /// Auto-convert every non-AU plugin that has a matching installed AU.
  func autoConvertAllPlugins() {
    var converted = 0, missed = 0
    for d in devices where d.format == .vst || d.format == .vst3 {
      if autoConvert(d) { converted += 1 } else { missed += 1 }
    }
    status = "Auto-matched \(converted) plugin(s)"
      + (missed > 0 ? " · \(missed) with no installed AU match" : "")
  }

  // MARK: Save

  func save(to destination: URL) {
    guard let document else { return }
    var replaced = 0
    for device in devices {
      guard case .replaceAU(let au) = action(for: device) else { continue }
      let newEl = DeviceBuilder.makeAUDevice(from: device, target: au)
      let idx = device.element.index
      device.parent.replaceChild(at: idx, with: newEl)
      replaced += 1
    }
    do {
      try document.save(to: destination)
      // Re-sync to the mutated DOM so the UI reflects the saved state.
      let found = DeviceExtractor.extractAll(document.root)
      devices = found
      actions = Dictionary(uniqueKeysWithValues: found.map { ($0.id, .keep) })
      status = "Saved \(destination.lastPathComponent) · replaced \(replaced) device(s)"
    } catch {
      status = "Save failed: \(error)"
    }
  }
}
