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
  /// A different plugin that does the same job (AMBEO Orbit → dearVR MICRO,
  /// FabFilter Pro-C → Pro-C 2).
  case substitute(Substitution, PluginTarget)
}

/// The devices of one plugin in a set, which get one choice together.
struct PluginGroup: Identifiable {
  let id: String
  let name: String
  let format: DeviceFormat
  var devices: [Device]

  /// Track names, once each, in set order.
  var tracks: [String] {
    var seen = Set<String>()
    return devices.map(\.trackName).filter { seen.insert($0).inserted }
  }

  /// Devices of the same plugin share a name, format and plugin id.
  static func key(for device: Device) -> String {
    let identity = device.uniqueId ?? device.vst3Uid.map { $0.map(String.init).joined(separator: ",") }
      ?? [device.auType, device.auSubType, device.auManufacturer].compactMap { $0 }.joined(separator: "/")
    return "\(device.format.rawValue):\(device.product.lowercased()):\(identity)"
  }
}

/// The state of one open Live Set: its DOM, its plugins, and what fixing it does.
///
/// Each plugin device has a recommended action (what it needs to load in a native
/// Live, with the replacements turned on in Settings); the user can override it
/// per plugin. Overrides are all that `actions` holds.
@MainActor
final class SetModel: ObservableObject {
  let url: URL
  private let catalogs: PluginCatalogs
  /// Called after a file is written, so the library can refresh its statuses.
  var onSaved: (() -> Void)?

  @Published private(set) var document: AlsDocument?
  @Published private(set) var loadError: String?
  @Published private(set) var devices: [Device] = []
  /// Plugin devices grouped by plugin, in set order.
  @Published private(set) var groups: [PluginGroup] = []
  /// Per-device overrides of the recommended action, keyed by device id.
  @Published private(set) var actions: [UUID: SlotAction] = [:]
  @Published private(set) var isSaving = false
  /// The last save's outcome, in a line.
  @Published private(set) var status: String?
  /// Per-device conversion warnings and failures from the last save.
  @Published private(set) var report: [String] = []
  /// The DOM holds replacements that haven't reached a file (a write failed).
  private var hasUnsavedEdits = false
  private var isLoading = false
  /// The source file's date when loaded, to notice it changing on disk.
  private(set) var loadedModified: Date?

  var fileName: String { url.lastPathComponent }
  /// The user changed what fixing does.
  var hasChanges: Bool { hasUnsavedEdits || !actions.isEmpty }
  var predatesVst3: Bool { document?.predatesVst3 == true }

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
      adopt(found)
      loadedModified = Self.modified(url)
    case .failure(let error):
      loadError = String(describing: error)
    }
  }

  private func adopt(_ found: [Device]) {
    devices = found
    actions = [:]
    var byKey: [String: Int] = [:]
    var out: [PluginGroup] = []
    for device in found where device.format != .native && device.format != .m4l {
      let key = PluginGroup.key(for: device)
      if let i = byKey[key] {
        out[i].devices.append(device)
      } else {
        byKey[key] = out.count
        out.append(PluginGroup(id: key, name: device.product, format: device.format, devices: [device]))
      }
    }
    groups = out
  }

  var isStaleOnDisk: Bool {
    guard let loadedModified else { return false }
    return Self.modified(url) != loadedModified
  }

  private static func modified(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  /// Live's own devices and Max for Live devices, which always load.
  var builtInCount: Int { devices.filter { ($0.format == .native && !$0.isRack) || $0.format == .m4l }.count }

  // MARK: What each plugin does

  /// How a device loads in a native Live, with the default replacements.
  func load(of device: Device) -> PluginLoad? { catalogs.effectiveInventory?.load(device) }

  /// What fixing does to a device unless the user says otherwise: only what it
  /// needs to load.
  func recommendedAction(for device: Device) -> SlotAction {
    switch load(of: device) {
    case .needsConversion(let target)?:
      return predatesVst3 ? .keep : .replaceVST3(target)
    case .substitute(let sub, let target)?:
      return predatesVst3 && !sub.worksBefore10(target) ? .keep : .substitute(sub, target)
    default:
      return .keep
    }
  }

  func action(for device: Device) -> SlotAction { actions[device.id] ?? recommendedAction(for: device) }

  func action(for group: PluginGroup) -> SlotAction { group.devices.first.map(action(for:)) ?? .keep }

  func setAction(_ action: SlotAction, for group: PluginGroup) {
    for device in group.devices {
      if action == recommendedAction(for: device) { actions[device.id] = nil } else { actions[device.id] = action }
    }
  }

  func resetChoices() { actions = [:] }

  /// Will this plugin load once the set is fixed?
  func willLoad(_ group: PluginGroup) -> Bool {
    guard let device = group.devices.first else { return true }
    switch action(for: device) {
    case .keep:
      if case .stuck? = load(of: device) { return false }
      if case .needsConversion? = load(of: device) { return false }
      if case .substitute? = load(of: device) { return false }
      return true
    case .replaceAU(let au): return au.isNative
    case .replaceVST3, .substitute: return true
    }
  }

  /// Groups fixing changes.
  var changingGroups: [PluginGroup] { groups.filter { action(for: $0) != .keep } }
  /// Groups that won't load after fixing.
  var brokenGroups: [PluginGroup] { groups.filter { !willLoad($0) } }

  /// `nil` for anything that isn't a VST2 device or an AU with a VST3 replacing it.
  func vst3Availability(of device: Device) -> Vst3Availability? {
    if device.format == .vst {
      if predatesVst3 { return .unavailable("re-save in Live 10+ first") }
      if catalogs.isLoadingVst3 { return .unavailable("scanning VST3s…") }
    }
    // Only an AU that can't load natively (Massive's AU is native; OTT's isn't).
    if device.format == .au {
      guard let au = LiveSetScan.AuPlugin(device: device), let inventory = catalogs.inventory,
            case .needsConversion = inventory.load(au) else { return nil }
    }
    guard let availability = Vst3Availability.resolve(device, catalog: catalogs.vst3) else { return nil }
    if predatesVst3 { return .unavailable("re-save in Live 10+ first") }
    return availability
  }

  /// A VST2 device whose own build is native, so it loads without converting.
  func loadsNativelyAsVst2(_ device: Device) -> Bool {
    device.format == .vst && load(of: device) == .native
  }

  /// The installed AU whose name best matches this device (for auto-suggest).
  func suggestedAU(for device: Device) -> AudioUnitInfo? {
    guard device.format != .au else { return nil }
    let want = device.product.lowercased()
    guard !want.isEmpty else { return nil }
    // Prefer an exact name match; fall back to contains.
    if let exact = catalogs.audioUnits.first(where: { $0.name.lowercased() == want && $0.isNative }) {
      return exact
    }
    return catalogs.audioUnits.first {
      $0.isNative && ($0.name.lowercased().contains(want) || want.contains($0.name.lowercased()))
    }
  }

  // MARK: Save

  private var alsType: UTType { UTType(filenameExtension: "als") ?? .data }

  var canFix: Bool { document != nil && !catalogs.isHostingPlugins && (!changingGroups.isEmpty || hasUnsavedEdits) }

  /// Saves the fixed set as a new file beside the original, which stays as it is.
  func presentSavePanel() {
    guard canFix else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [alsType]
    let base = url.deletingPathExtension().lastPathComponent
    // The library recognizes these names as copies of their original.
    let toAU = devices.contains {
      if case .replaceAU = action(for: $0) { return true }
      return false
    }
    panel.nameFieldStringValue = base + (toAU ? "-converted" : LibraryDiscovery.convertedSuffix) + ".als"
    panel.directoryURL = url.deletingLastPathComponent()
    panel.message = "The fixed copy is saved as a new set. “\(fileName)” stays as it is."
    if panel.runModal() == .OK, let url = panel.url { save(to: url) }
  }

  func save(to destination: URL) {
    guard document != nil, !catalogs.isHostingPlugins else { return }
    guard destination.standardizedFileURL != url.standardizedFileURL else {
      status = "Not saved: choose a new name, so the original stays as it is."
      return
    }
    catalogs.isHostingPlugins = true
    isSaving = true
    Task {
      await performSave(to: destination)
      isSaving = false
      catalogs.isHostingPlugins = false
      onSaved?()
    }
  }

  private func performSave(to destination: URL) async {
    guard let document else { return }
    let pending = devices.filter { action(for: $0) != .keep }
    let automated = document.automatedTargetIds
    var toVst3 = 0, toAU = 0, replaced = 0, warnings = 0, failures = 0
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
        status = "Converting \(i + 1) of \(pending.count): \(device.name)…"
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
      case .substitute(let sub, let target):
        status = "Replacing \(i + 1) of \(pending.count): \(device.name)…"
        await Task.yield()
        do {
          let c = try await sub.convert(device, target: target, document: document, automatedTargets: automated)
          c.apply(replacing: device)
          replaced += 1
          warnings += c.notes.count
          lines += c.notes.map { "\(label): \($0)" }
          hasUnsavedEdits = true
        } catch {
          failures += 1
          lines.append("\(label): not replaced: \(error)")
        }
        continue
      }
      device.parent.replaceChild(at: device.element.index, with: replacement)
      hasUnsavedEdits = true
    }

    report = lines
    guard hasUnsavedEdits else {
      status = "Nothing saved · \(failures) device(s) failed to convert"
      return
    }

    // Built with appends: as one `+` chain of ternaries this took the type
    // checker ~13s, half the release build.
    var notes: [String] = []
    if toVst3 > 0 { notes.append("\(toVst3) to VST3") }
    if toAU > 0 { notes.append("\(toAU) to AU") }
    if replaced > 0 { notes.append("\(replaced) replaced") }
    if warnings > 0 { notes.append("\(warnings) note(s)") }
    if failures > 0 { notes.append("\(failures) failed") }
    do {
      try document.save(to: destination)
      hasUnsavedEdits = false
      status = "Saved \(destination.lastPathComponent) · " + notes.joined(separator: " · ")
    } catch {
      status = "Save failed: \(error)"
    }

    // Replaced elements are detached from the DOM, so always re-sync: acting on
    // the old devices again would replace the wrong children.
    adopt(DeviceExtractor.extractAll(document.root))
  }
}
