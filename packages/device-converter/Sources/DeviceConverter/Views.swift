import SwiftUI

/// The device view for one Live Set.
struct ContentView: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: ConverterModel
  @State private var onlyConvertible = true
  @State private var choosingFor: Device?

  private var visibleDevices: [Device] {
    onlyConvertible ? model.devices.filter(\.isConvertible) : model.devices
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if let error = model.loadError {
        ContentUnavailableView(
          "Couldn't open \(model.fileName)", systemImage: "exclamationmark.triangle",
          description: Text(error))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.document == nil {
        ProgressView("Opening \(model.fileName)…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if visibleDevices.isEmpty {
        ContentUnavailableView {
          Label("No VST2 or VST3 devices", systemImage: "checkmark.circle")
        } description: {
          Text("This set has nothing to convert.")
        } actions: {
          Button("Show all devices") { onlyConvertible = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        columnHeader
        Divider()
        List {
          ForEach(visibleDevices) { device in
            DeviceRow(device: device, flat: onlyConvertible, choosingFor: $choosingFor)
              .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
          }
        }
        .listStyle(.plain)
        // Rebuild rather than diff when the filter flips: growing the table in
        // place triggers AppKit's NSTableView reentrancy warning.
        .id(onlyConvertible)
      }
      Divider()
      statusBar
    }
    .frame(minWidth: 640, minHeight: 520)
    .disabled(catalogs.isHostingPlugins)
    .task { await model.loadIfNeeded() }
    .sheet(item: $choosingFor) { device in
      ChooseAUView(device: device) { au in
        model.setAction(.replaceAU(au), for: device)
        choosingFor = nil
      } onCancel: {
        choosingFor = nil
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      if case .set = app.root {
        Button { app.presentOpenPanel() } label: {
          Label("Open", systemImage: "folder")
        }
      }
      Button { model.convertAllToVst3() } label: {
        Label("Convert VST2 to VST3", systemImage: "wand.and.stars")
      }
      .help("Queue every VST2 device with a native VST3 replacement. Settings are kept.")
      .disabled(model.devices.isEmpty || catalogs.isLoadingVst3)

      Spacer()

      Toggle("Only convertible", isOn: $onlyConvertible)
        .toggleStyle(.checkbox)
        .disabled(model.devices.isEmpty)

      Button { model.presentSavePanel() } label: {
        Label("Save As…", systemImage: "square.and.arrow.down")
      }
      .keyboardShortcut("s")
      .disabled(!model.hasChanges)
    }
    .padding(8)
  }

  private var columnHeader: some View {
    HStack(spacing: 0) {
      Text("Device in file").frame(maxWidth: .infinity, alignment: .leading)
      Text("").frame(width: 28)
      Text("Replace with").frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 16).padding(.vertical, 4)
  }

  private var statusBar: some View {
    HStack {
      Text(model.fileName).font(.caption).foregroundStyle(.secondary)
      Spacer()
      if catalogs.isLoading {
        Text("Scanning plugins…").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("\(catalogs.vst3.count) native VST3s · \(catalogs.audioUnits.count) AUs installed")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(model.status).font(.caption).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle)
        .help(model.report.isEmpty ? model.status : model.report.joined(separator: "\n"))
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }
}

// MARK: - Row

struct DeviceRow: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: ConverterModel
  let device: Device
  /// Listing only some devices: drop rack indentation and name the track instead.
  let flat: Bool
  @Binding var choosingFor: Device?

  var body: some View {
    HStack(spacing: 0) {
      DeviceCell(device: device, flat: flat)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(device.enabled ? 1 : 0.5)

      if device.isConvertible {
        Image(systemName: "arrow.right")
          .foregroundStyle(.tertiary)
          .frame(width: 28)

        slot
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Spacer().frame(width: 28)
        Spacer().frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 2)
  }

  private var slot: some View {
    // The label sits beside the Menu, not inside it: macOS draws a Menu's label
    // as an AppKit pop-up button, keeping only its first image and text.
    HStack(spacing: 8) {
      slotLabel
      Spacer(minLength: 4)
      Menu("Change") { menuItems }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(catalogs.isLoadingAudioUnits)
    }
  }

  @ViewBuilder private var slotLabel: some View {
    switch model.action(for: device) {
    case .keep:
      SlotLabel(icon: "equal", title: device.name, subtitle: keepSubtitle,
                badge: device.format.badge, tint: .secondary)
    case .replaceVST3(let target):
      SlotLabel(icon: "checkmark.circle.fill", title: target.name,
                subtitle: "keeps settings", badge: "VST3", tint: .green)
    case .replaceAU(let au):
      SlotLabel(icon: "exclamationmark.triangle.fill", title: au.name,
                subtitle: "default settings", badge: "AU", tint: .orange)
    }
  }

  private var keepSubtitle: String {
    if model.loadsNativelyAsVst2(device) { return "already native" }
    if case .unavailable(let why) = model.vst3Availability(of: device) { return why }
    return "unchanged"
  }

  @ViewBuilder private var menuItems: some View {
    Button("Keep original") { model.setAction(.keep, for: device) }
    switch model.vst3Availability(of: device) {
    case .available(let target):
      Button("Convert to VST3 (keeps settings)") { model.setAction(.replaceVST3(target), for: device) }
    case .unavailable(let why):
      Button("VST3: \(why)") {}.disabled(true)
    case nil:
      EmptyView()
    }
    Divider()
    if let s = model.suggestedAU(for: device) {
      Button("Match AU → \(s.name) (default settings)") { model.setAction(.replaceAU(s), for: device) }
    }
    Button("Choose Audio Unit… (default settings)") { choosingFor = device }
  }
}

struct DeviceCell: View {
  let device: Device
  let flat: Bool

  var body: some View {
    HStack(spacing: 6) {
      Spacer().frame(width: flat ? 0 : CGFloat(device.depth) * 14)
      Image(systemName: categoryIcon(device.category, isRack: device.isRack))
        .foregroundStyle(.secondary).frame(width: 16)
      if let badge = device.format.badge {
        FormatBadge(text: badge)
      }
      Text(device.name).lineLimit(1)
      if device.product != device.name {
        Text(device.product).foregroundStyle(.secondary).lineLimit(1)
      }
      if let v = device.vstSdkVersion {
        Text("VST \(v)").font(.caption2).foregroundStyle(.tertiary)
      }
      if !device.enabled {
        Text("off").font(.caption2).foregroundStyle(.tertiary)
      }
      if flat {
        Text(device.trackName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .help(deviceTooltip(device))
  }
}

struct SlotLabel: View {
  let icon: String
  let title: String
  let subtitle: String
  var badge: String?
  var tint: Color

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
      if let badge { FormatBadge(text: badge) }
      Text(title).lineLimit(1)
      Text(subtitle).foregroundStyle(.secondary).lineLimit(1).font(.caption)
    }
  }
}

struct FormatBadge: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold))
      .padding(.horizontal, 4).padding(.vertical, 1)
      .background(.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
  }
}

// MARK: - Choose AU sheet

struct ChooseAUView: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  let device: Device
  let onPick: (AudioUnitInfo) -> Void
  let onCancel: () -> Void
  @State private var query = ""

  private var results: [AudioUnitInfo] {
    let all = catalogs.audioUnits
    guard !query.isEmpty else { return all }
    let q = query.lowercased()
    return all.filter {
      $0.name.lowercased().contains(q) || $0.manufacturer.lowercased().contains(q)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Replace “\(device.name)” with…").font(.headline)
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
      }
      .padding()

      Text("Audio Units load at their default settings: this device's settings won't carry over.")
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.bottom, 8)

      TextField("Search Audio Units", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal)

      List(results) { au in
        Button {
          onPick(au)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: au.isInstrument ? "pianokeys" : "slider.horizontal.3")
              .foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
              Text(au.name)
              Text("\(au.manufacturer) · \(au.typeFourCC)/\(au.subTypeFourCC)/\(au.manufacturerFourCC)")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .listStyle(.plain)
    }
    .frame(width: 520, height: 460)
  }
}

// MARK: - Icons / helpers

func categoryIcon(_ category: DeviceCategory, isRack: Bool) -> String {
  if isRack { return "square.stack.3d.up.fill" }
  switch category {
  case .instrument: return "pianokeys"
  case .audioEffect: return "slider.horizontal.3"
  case .midiEffect: return "music.note"
  case .unknown: return "cube"
  }
}

func deviceTooltip(_ d: Device) -> String {
  var parts = [d.type]
  if let v = d.vendor { parts.append(v) }
  if let v = d.vstSdkVersion { parts.append("VST \(v)") }
  if let id = d.uniqueId { parts.append("id \(id)") }
  return parts.joined(separator: " · ")
}
