import SwiftUI

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
