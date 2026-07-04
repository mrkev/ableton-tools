import SwiftUI

struct ContentView: View {
  @EnvironmentObject var model: ConverterModel
  @State private var onlyPlugins = false
  @State private var choosingFor: Device?

  private var visibleDevices: [Device] {
    onlyPlugins ? model.devices.filter { $0.format != .native } : model.devices
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if model.devices.isEmpty {
        emptyState
      } else {
        columnHeader
        Divider()
        List {
          ForEach(visibleDevices) { device in
            DeviceRow(device: device, choosingFor: $choosingFor)
              .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
          }
        }
        .listStyle(.plain)
      }
      Divider()
      statusBar
    }
    .frame(minWidth: 820, minHeight: 520)
    .sheet(item: $choosingFor) { device in
      ChooseAUView(device: device) { au in
        model.setAction(.replaceAU(au), for: device)
        choosingFor = nil
      } onCancel: {
        choosingFor = nil
      }
      .environmentObject(model)
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button { model.presentOpenPanel() } label: {
        Label("Open", systemImage: "folder")
      }
      Button { model.autoConvertAllPlugins() } label: {
        Label("Auto-convert plugins", systemImage: "wand.and.stars")
      }
      .disabled(model.devices.isEmpty)

      Spacer()

      Toggle("Only plugins", isOn: $onlyPlugins)
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
      if model.isLoadingCatalog {
        Text("Scanning Audio Units…").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("\(model.catalog.count) AUs installed").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(model.status).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "slider.horizontal.2.square.on.square")
        .font(.system(size: 40)).foregroundStyle(.secondary)
      Text("Open an Ableton Live Set to convert its plugin devices.")
        .foregroundStyle(.secondary)
      Button("Open .als…") { model.presentOpenPanel() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Row

struct DeviceRow: View {
  @EnvironmentObject var model: ConverterModel
  let device: Device
  @Binding var choosingFor: Device?

  var body: some View {
    HStack(spacing: 0) {
      DeviceCell(device: device)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(device.enabled ? 1 : 0.5)

      Image(systemName: "arrow.right")
        .foregroundStyle(.tertiary)
        .frame(width: 28)

      slot
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder private var slot: some View {
    let action = model.action(for: device)
    Menu {
      Button("Keep original") { model.setAction(.keep, for: device) }
      if let s = model.suggestedAU(for: device) {
        Button("Match → \(s.name)") { model.setAction(.replaceAU(s), for: device) }
      }
      Button("Choose Audio Unit…") { choosingFor = device }
    } label: {
      switch action {
      case .keep:
        SlotLabel(icon: "equal", title: device.name, subtitle: "unchanged",
                  badge: device.format.badge, tint: .secondary)
      case .replaceAU(let au):
        SlotLabel(icon: "checkmark.circle.fill", title: au.name,
                  subtitle: au.manufacturer, badge: "AU", tint: .green)
      }
    }
    .menuStyle(.borderlessButton)
    .disabled(model.isLoadingCatalog && device.format != .native)
  }
}

struct DeviceCell: View {
  let device: Device

  var body: some View {
    HStack(spacing: 6) {
      Spacer().frame(width: CGFloat(device.depth) * 14)
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
  @EnvironmentObject var model: ConverterModel
  let device: Device
  let onPick: (AudioUnitInfo) -> Void
  let onCancel: () -> Void
  @State private var query = ""

  private var results: [AudioUnitInfo] {
    let all = model.catalog
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
