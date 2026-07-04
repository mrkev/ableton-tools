import Foundation

enum DeviceFormat: String {
  case native, vst, vst3, au, m4l

  var badge: String? {
    switch self {
    case .native: return nil
    case .vst: return "VST2"
    case .vst3: return "VST3"
    case .au: return "AU"
    case .m4l: return "M4L"
    }
  }
}

enum DeviceCategory: String {
  case instrument, audioEffect, midiEffect, unknown
}

/// A device found in a track's chain, backed by its live `XMLElement` so it can
/// be replaced in place on save.
final class Device: Identifiable {
  let id = UUID()
  /// The device element in the DOM (e.g. `<PluginDevice>`, `<Operator>`).
  let element: XMLElement
  /// The `<Devices>` element it lives in (its parent), used for replacement.
  let parent: XMLElement

  let type: String
  let name: String
  let product: String
  let format: DeviceFormat
  let category: DeviceCategory
  let isRack: Bool
  let enabled: Bool
  let depth: Int
  let trackName: String

  var vendor: String?
  var vstSdkVersion: String?
  var uniqueId: String?
  /// AU component identifiers, decoded when this is an AU device.
  var auType: String?
  var auSubType: String?
  var auManufacturer: String?
  /// VST3 class UID (four int32 fields), when this is a VST3 device.
  var vst3Uid: [Int32]?

  init(element: XMLElement, parent: XMLElement, depth: Int, trackName: String) {
    self.element = element
    self.parent = parent
    self.depth = depth
    self.trackName = trackName

    let tag = element.name ?? "#unknown"
    self.type = tag
    self.isRack = DeviceExtractor.rackTags.contains(tag)
    self.format = DeviceExtractor.detectFormat(element, tag: tag)
    self.enabled = DeviceExtractor.deviceEnabled(element)

    let userName = element.childValue("UserName")?.trimmingCharacters(in: .whitespaces)
    let info = DeviceExtractor.pluginInfo(element, format: format, tag: tag)

    self.category = info.category
    self.product = info.product
    self.name = (userName?.isEmpty == false ? userName! : nil) ?? info.product
    self.vendor = info.vendor
    self.vstSdkVersion = info.vstSdkVersion
    self.uniqueId = info.uniqueId
    self.auType = info.auType
    self.auSubType = info.auSubType
    self.auManufacturer = info.auManufacturer
    self.vst3Uid = info.vst3Uid
  }
}
