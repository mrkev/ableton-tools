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

struct StatusIcon: View {
  let kind: SetStatus.Kind

  var body: some View {
    Image(systemName: kind.icon)
      .foregroundStyle(kind.tint)
      .frame(width: 16)
      .accessibilityLabel(kind.title)
  }
}

extension SetStatus.Kind {
  var tint: Color {
    switch self {
    case .afterConverting: return .blue
    case .converted, .opens: return .green
    case .resaveFirst: return .orange
    case .rosettaOnly: return .yellow
    case .stuck, .failed: return .red
    case .scanning: return .secondary
    }
  }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for i in row.indices {
        let size = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows = [Row()]
    for i in subviews.indices {
      let size = subviews[i].sizeThatFits(.unspecified)
      let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      if rows[rows.count - 1].width + extra > width && !rows[rows.count - 1].indices.isEmpty {
        rows.append(Row())
      }
      let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      rows[rows.count - 1].indices.append(i)
      rows[rows.count - 1].width += added
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
    }
    return rows.filter { !$0.indices.isEmpty }
  }
}

/// A table's column layout (which columns show, their order and widths),
/// remembered under `key`. Bind it with `columnCustomization: $columns`, and give
/// each column a `customizationID`; the header's context menu then shows and
/// hides them.
@propertyWrapper
struct StoredColumns<Row: Identifiable>: DynamicProperty {
  @AppStorage private var data: Data

  init(_ key: String) { _data = AppStorage(wrappedValue: Data(), key) }

  var wrappedValue: TableColumnCustomization<Row> {
    get { (try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data)) ?? .init() }
    nonmutating set { data = (try? JSONEncoder().encode(newValue)) ?? Data() }
  }

  var projectedValue: Binding<TableColumnCustomization<Row>> {
    Binding { wrappedValue } set: { wrappedValue = $0 }
  }
}
