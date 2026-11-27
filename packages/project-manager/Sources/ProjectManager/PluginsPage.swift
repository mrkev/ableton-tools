import SwiftUI

/// Every plugin in the library: what it needs, and which sets use it.
struct PluginsPage: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  @State private var filter = Filter.all
  @State private var sortOrder = [KeyPathComparator(\PluginUsage.setCount, order: .reverse)]
  @State private var selection: PluginUsage.ID?

  enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case attention = "Needs attention"
    case native = "Works natively"
    var id: String { rawValue }
  }

  private var rows: [PluginUsage] {
    let query = app.searchText.trimmingCharacters(in: .whitespaces)
    return app.plugins.filter { p in
      switch filter {
      case .all: true
      case .attention: p.verdict.rank < 3
      case .native: p.verdict == .native
      }
    }
    .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    .sorted(using: sortOrder)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Plugins").font(.title2.weight(.semibold))
          Text(summary).foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Show", selection: $filter) {
          ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      .padding(24)

      if catalogs.isLoading || (app.plugins.isEmpty && app.isScanning) {
        ProgressView("Looking at installed plugins…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
          TableColumn("Plugin", value: \.name) { p in
            HStack(spacing: 6) {
              FormatBadge(text: p.formatName)
              Text(p.name).lineLimit(1)
            }
          }
          .width(min: 140, ideal: 190)
          TableColumn("Status", value: \.verdictRank) { p in
            HStack(spacing: 6) {
              Image(systemName: p.verdict.icon).foregroundStyle(p.verdict.tint).frame(width: 16)
              Text(p.verdict.title).lineLimit(1)
              if let detail = p.verdict.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            .help([p.verdict.title, p.verdict.detail].compactMap { $0 }.joined(separator: ": "))
          }
          .width(min: 160, ideal: 280)
          TableColumn("Sets", value: \.setCount) { p in Text("\(p.setCount)").monospacedDigit() }
            .width(min: 40, ideal: 50)
          TableColumn("Uses", value: \.instances) { p in
            Text("\(p.instances)").monospacedDigit().foregroundStyle(.secondary)
          }
          .width(min: 40, ideal: 50)
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
          if let usage = app.plugins.first(where: { $0.id == selection }) {
            PluginInspector(usage: usage)
              .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
          }
        }
      }
    }
  }

  private var summary: String {
    let stuck = app.plugins.filter { if case .stuck = $0.verdict { true } else { false } }.count
    return "\(plural(app.plugins.count, "plugin")) across the library"
      + (stuck > 0 ? " · \(stuck) with no native version" : "")
  }
}

extension PluginVerdict {
  var icon: String {
    switch self {
    case .native: return "checkmark.circle.fill"
    case .converts: return "arrow.right.circle.fill"
    case .replaceable: return "arrow.triangle.swap"
    case .stuck: return "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch self {
    case .native: return .green
    case .converts: return .blue
    case .replaceable: return .orange
    case .stuck: return .red
    }
  }
}

/// One plugin: what to do about it, and the sets that use it.
private struct PluginInspector: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs
  let usage: PluginUsage

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            FormatBadge(text: usage.formatName)
            Text(usage.name).font(.title3.weight(.semibold))
          }
          Label(usage.verdict.title, systemImage: usage.verdict.icon)
            .foregroundStyle(usage.verdict.tint)
          if let detail = usage.verdict.detail {
            Text(detail).font(.callout).foregroundStyle(.secondary)
          }
        }
        if case .replaceable(let s) = usage.verdict {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Replace when fixing a set", isOn: catalogs.isOptedIn(s))
              .toggleStyle(.checkbox)
            Text(s.explanation).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Text("Used \(usage.instances == 1 ? "once" : "\(usage.instances) times") in \(plural(usage.setCount, "set"))")
          .font(.headline)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(usage.sets, id: \.self) { url in
            let context = app.context(for: url)
            Button { app.reveal(url) } label: {
              HStack(spacing: 6) {
                StatusIcon(kind: app.status(of: url).kind)
                VStack(alignment: .leading, spacing: 0) {
                  Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                  if let project = context.project, project.name != url.deletingPathExtension().lastPathComponent {
                    Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
