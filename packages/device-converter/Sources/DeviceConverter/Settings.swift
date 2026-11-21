import SwiftUI

/// Defaults for fixing sets.
struct SettingsView: View {
  @EnvironmentObject var app: AppModel
  @EnvironmentObject var catalogs: PluginCatalogs

  var body: some View {
    Form {
      Section {
        ForEach(Substitution.allCases) { sub in
          ReplacementOption(substitution: sub, usage: app.usage(of: sub, in: app.allSets))
        }
      } header: {
        Text("Replacements")
      } footer: {
        Text("Plugins with no native version that a different plugin can stand in for. Turned on, fixing a "
             + "set replaces them unless you choose otherwise on its page; turned off, you can still pick "
             + "the replacement for one set.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Fixed copies") {
        Text("Fixing saves a new set beside the original, named “<set>\(LibraryDiscovery.convertedSuffix).als”, "
             + "and never changes the original. The sidebar shows the copy under its set.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// The default for one substitution.
private struct ReplacementOption: View {
  @EnvironmentObject var catalogs: PluginCatalogs
  let substitution: Substitution
  let usage: (sets: Int, instances: Int)

  private var isInstalled: Bool {
    substitution.isInstalled(vst3: catalogs.vst3, audioUnits: catalogs.audioUnits)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Replace \(substitution.sourceName) with \(substitution.targetName)",
             isOn: catalogs.isOptedIn(substitution))
        .disabled(catalogs.isLoading || !isInstalled || catalogs.isHostingPlugins)
      Text((usage.sets > 0 ? "Used in \(plural(usage.sets, "set")). " : "") + substitution.explanation)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !catalogs.isLoading && !isInstalled {
        Text("Install \(substitution.targetName) to use this.").font(.caption).foregroundStyle(.orange)
      }
    }
  }
}
