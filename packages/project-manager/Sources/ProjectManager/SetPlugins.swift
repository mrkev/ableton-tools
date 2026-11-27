import SwiftUI

/// A set page's Plugins tab: each plugin, what fixing does to it, and the notes
/// from the last fix.
struct PluginsTab: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel
  @State private var choosingFor: PluginGroup?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.hasChanges {
        HStack {
          Spacer()
          Button("Use Recommended") { model.resetChoices() }
            .buttonStyle(.link)
            .help("Undo your choices: fix only what each plugin needs to load")
        }
      }
      if model.document == nil {
        if model.loadError == nil {
          ProgressView().controlSize(.small)
        }
      } else if model.groups.isEmpty {
        Text("No third-party plugins. Everything is Live's own devices.")
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(sortedGroups.enumerated()), id: \.element.id) { i, group in
            if i > 0 { Divider() }
            PluginGroupRow(group: group, choosingFor: $choosingFor)
              .padding(.vertical, 6).padding(.horizontal, 10)
          }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .disabled(catalogs.isHostingPlugins)
      }
      if model.document != nil, model.builtInCount > 0 {
        Text("Also \(model.builtInCount) of Live's own and Max for Live devices, which load as they are.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !model.report.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Notes from the last fix").font(.headline)
          ForEach(Array(model.report.enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        .padding(.top, 14)
      }
    }
    .sheet(item: $choosingFor) { group in
      ChooseAUView(device: group.devices[0]) { au in
        model.setAction(.replaceAU(au), for: group)
        choosingFor = nil
      } onCancel: {
        choosingFor = nil
      }
    }
  }

  /// Won't load first, then what fixing changes, then what already works.
  private var sortedGroups: [PluginGroup] {
    func rank(_ g: PluginGroup) -> Int {
      if !model.willLoad(g) { return 0 }
      return model.action(for: g) == .keep ? 2 : 1
    }
    return model.groups.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
  }
}

/// One plugin in the set: what happens to it, and the choice of what to do.
private struct PluginGroupRow: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  @EnvironmentObject var model: SetModel
  let group: PluginGroup
  @Binding var choosingFor: PluginGroup?
  @State private var expanded = false

  private struct Outcome {
    var icon: String
    var tint: Color
    var title: String
    var detail: String?
  }

  private var device: Device { group.devices[0] }

  private var outcome: Outcome {
    switch model.action(for: group) {
    case .keep:
      let replacement = catalogs.substitution(for: device).map { "can be replaced with \($0.0.targetName)" }
      switch model.load(of: device) {
      case .native?, nil:
        return Outcome(icon: "checkmark.circle.fill", tint: .green, title: "Works natively")
      case .stuck(let why)?:
        return Outcome(icon: "xmark.octagon.fill", tint: .red, title: "Won't load",
                       detail: [why, replacement].compactMap { $0 }.joined(separator: " · "))
      case .needsConversion?:
        return Outcome(icon: "xmark.octagon.fill", tint: .red, title: "Won't load unless converted",
                       detail: model.predatesVst3 ? "save in Live 10+ first" : "Intel only")
      case .substitute?:
        return Outcome(icon: "xmark.octagon.fill", tint: .red, title: "Won't load",
                       detail: ["Intel only", replacement].compactMap { $0 }.joined(separator: " · "))
      }
    case .replaceVST3(let target):
      let verb = model.loadsNativelyAsVst2(device) ? "Moves to" : "Becomes"
      return Outcome(icon: "arrow.right.circle.fill", tint: .blue, title: "\(verb) \(target.name) VST3",
                     detail: "keeps its settings")
    case .substitute(let sub, _):
      return Outcome(icon: "arrow.triangle.swap", tint: .blue, title: "Replaced with \(sub.targetName)",
                     detail: sub.outcome)
    case .replaceAU(let au):
      return Outcome(icon: "arrow.right.circle.fill", tint: .orange, title: "Becomes \(au.name) AU",
                     detail: "starts from its default settings")
    }
  }

  var body: some View {
    let o = outcome
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(group.devices) { d in
          HStack(spacing: 6) {
            Text(d.trackName)
            if d.name != d.product { Text("› \(d.name)").foregroundStyle(.secondary) }
            if !d.enabled { Text("off").foregroundStyle(.tertiary) }
          }
          .font(.caption)
        }
      }
      .padding(.leading, 30).padding(.top, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: o.icon).foregroundStyle(o.tint).frame(width: 16)
          .accessibilityLabel(o.title)
        if let badge = group.format.badge { FormatBadge(text: badge) }
        Text(group.name).lineLimit(1)
        Text(usage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 1) {
          Text(o.title).lineLimit(1)
          if let detail = o.detail, !detail.isEmpty {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Menu { menuItems } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose what fixing does with \(group.name)")
        .disabled(catalogs.isLoadingAudioUnits)
      }
      .contentShape(Rectangle())
      .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }
  }

  private var usage: String {
    let tracks = group.tracks
    let n = group.devices.count
    return tracks.count == 1 ? (n == 1 ? tracks[0] : "\(n)× on \(tracks[0])")
      : "\(n)× on \(tracks.count) tracks"
  }

  @ViewBuilder private var menuItems: some View {
    let recommended = model.recommendedAction(for: device)
    Button("Leave As Is") { model.setAction(.keep, for: group) }
    switch model.vst3Availability(of: device) {
    case .available(let target):
      Button("\(model.loadsNativelyAsVst2(device) ? "Move" : "Convert") to \(target.name) VST3 (keeps settings)") {
        model.setAction(.replaceVST3(target), for: group)
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
            model.setAction(.substitute(sub, target), for: group)
          }
        }
      } else {
        Button("\(sub.targetName): not installed") {}.disabled(true)
      }
    }
    Divider()
    if let au = model.suggestedAU(for: device) {
      Button("Use \(au.name) AU (default settings)") { model.setAction(.replaceAU(au), for: group) }
    }
    Button("Choose Audio Unit… (default settings)") { choosingFor = group }
    if model.action(for: group) != recommended {
      Divider()
      Button("Use Recommended") { model.setAction(recommended, for: group) }
    }
  }
}

