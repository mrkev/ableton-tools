import SwiftUI

/// A set page's Plugins tab: every plugin device in the set, how it loads now and
/// what fixing does to it.
struct SetPluginsTab: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel
  @State private var choosingAU: AUChoice?
  @State private var selection = Set<Device.ID>()
  @StoredColumns<PluginDeviceRow>("setPluginsTableColumns.2") private var columns
  @State private var sortOrder = [KeyPathComparator(\PluginDeviceRow.rank)]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.document == nil {
        if model.loadError == nil {
          ProgressView().controlSize(.small)
        }
      } else if model.groups.isEmpty {
        Text("No third-party plugins. Everything is Live's own devices.")
          .foregroundStyle(.secondary)
      } else {
        HStack {
          if model.builtInCount > 0 {
            Text("Also \(model.builtInCount) of Live's own and Max for Live devices, which load as they are.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if model.hasChanges {
            Button("Use Recommended") { model.resetChoices() }
              .buttonStyle(.link)
              .help("Undo your choices: fix only what each plugin needs to load")
          }
        }
        table
      }
      if !model.report.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Notes from the last fix").font(.headline)
          ForEach(Array(model.report.enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        .padding(.top, 6)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .sheet(item: $choosingAU) { choice in
      ChooseAUView(device: choice.devices[0]) { au in
        model.setAction(.replaceAU(au), for: choice.devices)
        choosingAU = nil
      } onCancel: {
        choosingAU = nil
      }
    }
  }

  private var rows: [PluginDeviceRow] {
    var order = 0
    return model.groups.flatMap { group in
      group.devices.map { device in
        defer { order += 1 }
        return PluginDeviceRow(device, in: group, model: model, catalogs: catalogs, order: order)
      }
    }
    .sorted(using: sortOrder)
  }

  private var table: some View {
    Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("Plugin", value: \.name) { row in
        HStack(spacing: 6) {
          Image(systemName: row.now.icon).foregroundStyle(row.now.tint).frame(width: 16)
            .accessibilityLabel(row.now.title)
          Text(row.name).lineLimit(1)
        }
      }
      .width(min: 100, ideal: 150)
      .customizationID("plugin")
      .disabledCustomizationBehavior(.visibility)
      TableColumn("Format", value: \.format) { row in
        if !row.format.isEmpty { FormatBadge(text: row.format) }
      }
      .width(min: 56, ideal: 58, max: 72)
      .customizationID("format")
      TableColumn("Track", value: \.track) { row in Text(row.track).lineLimit(1) }
        .width(min: 60, ideal: 130)
        .customizationID("track")
      TableColumn("Device", value: \.deviceName) { row in
        HStack(spacing: 6) {
          Text(row.deviceName).foregroundStyle(.secondary).lineLimit(1)
          if !row.device.enabled { Text("off").foregroundStyle(.tertiary) }
        }
        .help(row.device.enabled ? row.device.name : "\(row.device.name) (switched off)")
      }
      .width(min: 60, ideal: 110)
      .customizationID("device")
      TableColumn("Loads Now", value: \.nowRank) { row in
        Text(row.now.title).foregroundStyle(row.now.tint == .green ? .primary : row.now.tint).lineLimit(1)
          .help(row.now.detail ?? row.now.title)
      }
      .width(min: 84, ideal: 100)
      .customizationID("loadsnow")
      TableColumn("When Fixed", value: \.fix.title) { row in
        Menu {
          PluginActionItems(devices: [row.device], choosingAU: $choosingAU)
        } label: {
          Label(row.fix.title, systemImage: row.fix.icon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(row.fix.detail.map { "\(row.fix.title): \($0)" } ?? row.fix.title)
        .disabled(catalogs.isLoadingAudioUnits || catalogs.isHostingPlugins)
      }
      .width(min: 100, ideal: 180)
      .customizationID("whenfixed")
    }
    .contextMenu(forSelectionType: Device.ID.self) { ids in
      let chosen = model.devices.filter { ids.contains($0.id) }
      // One plugin's choices fit all its devices; mixed plugins share only these.
      if let first = chosen.first, chosen.allSatisfy({ PluginGroup.key(for: $0) == PluginGroup.key(for: first) }) {
        PluginActionItems(devices: chosen, choosingAU: $choosingAU)
      } else if !chosen.isEmpty {
        Button("Leave As Is") { model.setAction(.keep, for: chosen) }
        Button("Use Recommended") {
          for device in chosen { model.setAction(model.recommendedAction(for: device), for: [device]) }
        }
      }
    }
    .frame(minHeight: 0, maxHeight: .infinity)
  }
}

/// Devices waiting on the Audio Unit picker.
private struct AUChoice: Identifiable {
  let id = UUID()
  let devices: [Device]
}

// MARK: - Rows

/// What a column says about a device: an icon, a few words, and why.
private struct PluginOutcome {
  var icon: String
  var tint: Color
  var title: String
  var detail: String?
}

/// One plugin device in the set, ready for the table.
private struct PluginDeviceRow: Identifiable {
  let device: Device
  let name: String
  let format: String
  let track: String
  /// The device's own name, when it was renamed from the plugin's.
  let deviceName: String
  /// How it loads in a native Live as the set is.
  let now: PluginOutcome
  /// What fixing does to it.
  let fix: PluginOutcome
  /// Won't load first, then what fixing changes, then what already works; set
  /// order within each.
  let rank: Int
  let nowRank: Int

  var id: Device.ID { device.id }

  @MainActor init(_ device: Device, in group: PluginGroup, model: SetModel, catalogs: PluginCatalogs, order: Int) {
    self.device = device
    name = group.name
    format = group.format.badge ?? ""
    track = device.trackName
    deviceName = device.name == device.product ? "" : device.name
    let replacement = catalogs.substitution(for: device).map { "can be replaced with \($0.0.targetName)" }
    let fixable = model.predatesVst3 ? "save in Live 10+ to convert" : nil
    // What matters is the architecture of the build the device's format loads:
    // an Intel build still loads in Live under Rosetta; nothing else does.
    let installed = model.installed(of: device)
    let rosetta = installed?.architecture == .x86_64
    /// Why its own build doesn't load natively: "32-bit only", "not installed"…
    let build = installed.map { $0.architecture == .native ? "different plugin ID" : $0.architecture.only }
      ?? "not installed"
    func notNative(_ why: String?, _ more: String? = nil) -> PluginOutcome {
      rosetta
        ? PluginOutcome(icon: "exclamationmark.triangle.fill", tint: .yellow, title: "Rosetta only",
                        detail: ["loads when Live runs under Rosetta", more, replacement].compactMap { $0 }
                          .joined(separator: " · "))
        : PluginOutcome(icon: "xmark.octagon.fill", tint: .red, title: "Won't load",
                        detail: [why, more, replacement].compactMap { $0 }.joined(separator: " · "))
    }
    switch model.load(of: device) {
    case .native?, nil:
      now = PluginOutcome(icon: "checkmark.circle.fill", tint: .green, title: "Native")
      nowRank = 2
    case .stuck(let why)?:
      now = notNative(why)
      nowRank = rosetta ? 1 : 0
    case .needsConversion?:
      now = notNative(build, fixable)
      nowRank = rosetta ? 1 : 0
    case .substitute?:
      now = notNative(build)
      nowRank = rosetta ? 1 : 0
    }

    let action = model.action(for: device)
    switch action {
    case .keep:
      switch nowRank {
      case 2: fix = PluginOutcome(icon: "minus.circle", tint: .secondary, title: "Nothing to do")
      case 1: fix = PluginOutcome(icon: "exclamationmark.triangle", tint: .yellow, title: "Still Rosetta only",
                                  detail: now.detail)
      default: fix = PluginOutcome(icon: "xmark.octagon", tint: .red, title: "Still won't load", detail: now.detail)
      }
    case .replaceVST3:
      // Its own VST3, matched by the VST2 id it replaces, and always native.
      // A VST2 that's already native only changes format.
      fix = PluginOutcome(icon: "arrow.right.circle.fill", tint: .blue,
                          title: model.loadsNativelyAsVst2(device) ? "Moves to VST3" : "Becomes native (VST3)",
                          detail: "keeps its settings")
    case .substitute(let sub, _):
      fix = PluginOutcome(icon: "arrow.triangle.swap", tint: .blue, title: "Replaced with \(sub.targetName)",
                          detail: sub.outcome)
    case .replaceAU(let au):
      fix = PluginOutcome(icon: "arrow.right.circle.fill", tint: .orange, title: "Becomes \(au.name) AU",
                          detail: "starts from its default settings")
    }
    let urgency = !model.willLoad(device) ? 0 : action == .keep ? 2 : 1
    rank = urgency * 100_000 + order
  }
}

// MARK: - Choosing what fixing does

/// What fixing can do with devices of one plugin: a row's When Fixed menu, or the
/// context menu for the rows selected.
private struct PluginActionItems: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel
  /// Devices of the same plugin.
  let devices: [Device]
  @Binding var choosingAU: AUChoice?

  private var device: Device { devices[0] }

  var body: some View {
    Button("Leave As Is") { model.setAction(.keep, for: devices) }
    switch model.vst3Availability(of: device) {
    case .available(let target):
      Button(model.loadsNativelyAsVst2(device) ? "Move to VST3 (keeps settings)"
             : "Convert to native (VST3), keeps settings") {
        model.setAction(.replaceVST3(target), for: devices)
      }
    case .unavailable(let why):
      Button("VST3: \(why)") {}.disabled(true)
    case nil:
      EmptyView()
    }
    if let sub = Substitution.matching(device) {
      if let (_, target) = catalogs.substitution(for: device) {
        if model.predatesVst3 && !sub.worksBefore10(target) {
          Button("\(sub.targetName): save in Live 10+ first") {}.disabled(true)
        } else {
          Button("Replace with \(sub.targetName) (\(sub.outcome.replacingOccurrences(of: " · ", with: ", ")))") {
            model.setAction(.substitute(sub, target), for: devices)
          }
        }
      } else {
        Button("\(sub.targetName): not installed") {}.disabled(true)
      }
    }
    Divider()
    if let au = model.suggestedAU(for: device) {
      Button("Use \(au.name) AU (default settings)") { model.setAction(.replaceAU(au), for: devices) }
    }
    Button("Choose Audio Unit… (default settings)") { choosingAU = AUChoice(devices: devices) }
    if devices.contains(where: { model.action(for: $0) != model.recommendedAction(for: $0) }) {
      Divider()
      Button("Use Recommended") {
        for device in devices { model.setAction(model.recommendedAction(for: device), for: [device]) }
      }
    }
  }
}
