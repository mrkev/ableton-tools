import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// What a slot on the right-hand column resolves to.
enum SlotAction: Equatable, Codable {
  case keep
  /// Loads at the AU's default settings: the plugin's state can't be carried over.
  case replaceAU(AudioUnitInfo)
  /// Carries the plugin's state and parameter slots over.
  case replaceVST3(Vst3PluginInfo)
}

/// The state of one open Live Set: its DOM, devices and per-device choices.
@MainActor
final class ConverterModel: ObservableObject {
  let url: URL
  private let catalogs: PluginCatalogs
  /// Called after a file is written, so the library can refresh its statuses.
  var onSaved: (() -> Void)?

  @Published private(set) var document: AlsDocument?
  @Published private(set) var loadError: String?
  @Published private(set) var devices: [Device] = []
  /// Per-device slot decision, keyed by device id.
  @Published var actions: [UUID: SlotAction] = [:]
  @Published var status: String = "Opening…"
  /// Per-device conversion warnings and failures from the last save.
  @Published private(set) var report: [String] = []
  /// The DOM holds replacements that haven't reached a file (a write failed).
  private var hasUnsavedEdits = false
  private var isLoading = false
  /// The source file's date when loaded, to notice it changing on disk.
  private(set) var loadedModified: Date?

  var fileName: String { url.lastPathComponent }
  var hasChanges: Bool { hasUnsavedEdits || actions.values.contains { $0 != .keep } }
  var convertibleCount: Int { devices.filter(\.isConvertible).count }

  init(url: URL, catalogs: PluginCatalogs) {
    self.url = url
    self.catalogs = catalogs
  }

  // MARK: Loading

  /// Parses off the main thread, since a large set takes seconds. The parsed
  /// objects are handed over once and only touched on the main actor after.
  func loadIfNeeded() async {
    guard document == nil, loadError == nil, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    let url = url
    let loaded = await Task.detached(priority: .userInitiated) { () -> Result<(AlsDocument, [Device]), Error> in
      Result {
        let doc = try AlsDocument(url: url)
        return (doc, DeviceExtractor.extractAll(doc.root))
      }
    }.value
    switch loaded {
    case .success(let (doc, found)):
      document = doc
      devices = found
      actions = Dictionary(uniqueKeysWithValues: found.map { ($0.id, .keep) })
      loadedModified = Self.modified(url)
      status = "\(found.count) devices · \(convertibleCount) convertible"
        + (doc.predatesVst3 && found.contains { $0.format == .vst }
          ? " · saved by \(doc.creator): re-save in Live 10+ to convert to VST3" : "")
    case .failure(let error):
      loadError = String(describing: error)
      status = "Couldn't open \(fileName)"
    }
  }

  var isStaleOnDisk: Bool {
    guard let loadedModified else { return false }
    return Self.modified(url) != loadedModified
  }

  private static func modified(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  // MARK: Slots

  func action(for device: Device) -> SlotAction { actions[device.id] ?? .keep }

  func setAction(_ action: SlotAction, for device: Device) {
    actions[device.id] = action
  }

  /// `nil` for anything that isn't a VST2 device.
  func vst3Availability(of device: Device) -> Vst3Availability? {
    guard device.format == .vst else { return nil }
    if document?.predatesVst3 == true { return .unavailable("re-save in Live 10+ first") }
    if catalogs.isLoadingVst3 { return .unavailable("scanning VST3s…") }
    return Vst3Availability.resolve(
      LiveSetScan.Vst2Plugin(
        name: device.product, uniqueId: Vst3Migration.vst2UniqueId(device),
        isChunk: Vst2State.isChunkPreset(device.element)),
      catalog: catalogs.vst3)
  }

  /// The installed AU whose name best matches this device (for auto-suggest).
  func suggestedAU(for device: Device) -> AudioUnitInfo? {
    let want = device.product.lowercased()
    guard !want.isEmpty else { return nil }
    // Prefer an exact name match; fall back to contains.
    if let exact = catalogs.audioUnits.first(where: { $0.name.lowercased() == want }) {
      return exact
    }
    return catalogs.audioUnits.first {
      $0.name.lowercased().contains(want) || want.contains($0.name.lowercased())
    }
  }

  /// Queue every VST2 device with a usable VST3 for conversion. Audio Units are
  /// left to explicit per-device choices, since they lose the plugin's settings.
  func convertAllToVst3() {
    var queued = 0
    var unavailable: [String] = []
    for d in devices where d.format == .vst {
      if case .available(let target) = vst3Availability(of: d) {
        setAction(.replaceVST3(target), for: d)
        queued += 1
      } else {
        unavailable.append(d.name)
      }
    }
    status = "\(queued) VST2 device(s) will convert to VST3 on save"
      + (unavailable.isEmpty ? "" : " · \(unavailable.count) can't: "
        + Set(unavailable).sorted().joined(separator: ", "))
  }

  // MARK: Save

  private var alsType: UTType { UTType(filenameExtension: "als") ?? .data }

  func presentSavePanel() {
    guard document != nil, !catalogs.isHostingPlugins, hasChanges else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [alsType]
    let base = url.deletingPathExtension().lastPathComponent
    // The library recognizes `-vst3` files as conversions of their original.
    let onlyVst3 = actions.values.allSatisfy {
      if case .replaceAU = $0 { return false }
      return true
    }
    panel.nameFieldStringValue = base + (onlyVst3 ? LibraryDiscovery.convertedSuffix : "-converted") + ".als"
    panel.directoryURL = url.deletingLastPathComponent()
    if panel.runModal() == .OK, let url = panel.url { save(to: url) }
  }

  func save(to destination: URL) {
    guard document != nil, !catalogs.isHostingPlugins else { return }
    catalogs.isHostingPlugins = true
    Task {
      await performSave(to: destination)
      catalogs.isHostingPlugins = false
      onSaved?()
    }
  }

  private func performSave(to destination: URL) async {
    guard let document else { return }
    let pending = devices.filter { action(for: $0) != .keep }
    let automated = document.automatedTargetIds
    var toVst3 = 0, toAU = 0, warnings = 0, failures = 0
    var lines: [String] = []

    for (i, device) in pending.enumerated() {
      let label = "\(device.trackName) › \(device.name)"
      let replacement: XMLElement
      switch action(for: device) {
      case .keep:
        continue
      case .replaceAU(let au):
        replacement = DeviceBuilder.makeAUDevice(from: device, target: au)
        toAU += 1
      case .replaceVST3(let target):
        status = "Converting \(i + 1)/\(pending.count): \(device.name)…"
        await Task.yield()
        do {
          let c = try Vst3Migration.prepare(device, target: target, automatedTargets: automated)
          replacement = DeviceBuilder.makeVst3Device(from: device, conversion: c)
          toVst3 += 1
          warnings += c.warnings.count
          lines += c.warnings.map { "\(label): \($0)" }
        } catch {
          failures += 1
          lines.append("\(label): not converted: \(error)")
          continue
        }
      }
      device.parent.replaceChild(at: device.element.index, with: replacement)
      hasUnsavedEdits = true
    }

    report = lines
    guard hasUnsavedEdits else {
      status = "Nothing saved · \(failures) device(s) failed to convert"
      return
    }

    let notes = (toVst3 > 0 ? ["\(toVst3) to VST3"] : []) + (toAU > 0 ? ["\(toAU) to AU"] : [])
      + (warnings > 0 ? ["\(warnings) warning(s)"] : []) + (failures > 0 ? ["\(failures) failed"] : [])
    do {
      try document.save(to: destination)
      hasUnsavedEdits = false
      status = "Saved \(destination.lastPathComponent) · " + notes.joined(separator: " · ")
    } catch {
      status = "Save failed: \(error)"
    }

    // Replaced elements are detached from the DOM, so always re-sync: acting on
    // the old devices again would replace the wrong children.
    let found = DeviceExtractor.extractAll(document.root)
    devices = found
    actions = Dictionary(uniqueKeysWithValues: found.map { ($0.id, .keep) })
  }
}
