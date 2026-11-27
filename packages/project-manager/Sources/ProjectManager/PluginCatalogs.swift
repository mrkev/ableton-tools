import Foundation
import SwiftUI

/// Installed plugins, shared by every open set.
@MainActor
final class PluginCatalogs: ObservableObject {
  @Published private(set) var audioUnits: [AudioUnitInfo] = []
  @Published private(set) var isLoadingAudioUnits = true
  @Published private(set) var vst3: [Vst3PluginInfo] = []
  @Published private(set) var isLoadingVst3 = true
  /// Everything installed, once all of it is known.
  @Published private(set) var inventory: PluginInventory?
  /// A save or batch is converting. Only one conversion runs at a time, and the
  /// UI that could start another is disabled meanwhile.
  @Published var isHostingPlugins = false
  /// Opted-in replacements of plugins by different ones. Remembered.
  @Published var substitutions = Set(Substitution.allCases.filter { UserDefaults.standard.bool(forKey: $0.defaultsKey) }) {
    didSet {
      for s in Substitution.allCases { UserDefaults.standard.set(substitutions.contains(s), forKey: s.defaultsKey) }
    }
  }

  func isOptedIn(_ s: Substitution) -> Binding<Bool> {
    Binding(get: { self.substitutions.contains(s) }, set: { on in
      if on { self.substitutions.insert(s) } else { self.substitutions.remove(s) }
    })
  }

  var isLoading: Bool { inventory == nil }

  /// `inventory` with the opt-ins applied.
  var effectiveInventory: PluginInventory? {
    inventory.map {
      var out = $0
      out.substitutions = substitutions
      return out
    }
  }

  /// The replacement installed for a device, opted in or not (a device can be
  /// replaced on its own).
  func substitution(for device: Device) -> (Substitution, PluginTarget)? {
    guard let s = Substitution.matching(device),
          let target = s.target(for: device.format, vst3: vst3, audioUnits: audioUnits) else { return nil }
    return (s, target)
  }

  init() {
    Task {
      let others = await Task.detached(priority: .userInitiated) {
        (AudioUnitCatalog.installed(), PluginInventory.vst2Bundles(), PluginInventory.vst3BundleArchitectures())
      }.value
      audioUnits = others.0
      isLoadingAudioUnits = false
      // On the main actor (plugins expect their code to load on the main thread),
      // yielding between bundles so the window stays responsive.
      var found: [Vst3PluginInfo] = []
      for bundle in Vst3Catalog.bundles() {
        found += Vst3Catalog.classes(in: bundle)
        await Task.yield()
      }
      vst3 = found
      isLoadingVst3 = false
      inventory = PluginInventory(vst3: found, vst3Bundles: others.2, vst2Files: others.1, audioUnits: others.0)
    }
  }
}
