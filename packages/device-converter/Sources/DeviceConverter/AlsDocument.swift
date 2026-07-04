import Foundation

/// An open Ableton Live Set: the decompressed XML tree plus the source URL.
///
/// The DOM (`XMLDocument`) is the single source of truth. Conversions mutate
/// it surgically — replacing only the device subtrees the user changed — so
/// every other byte round-trips untouched.
final class AlsDocument {
  let sourceURL: URL
  let xml: XMLDocument
  /// The root `<Ableton>` element.
  let root: XMLElement

  init(url: URL) throws {
    self.sourceURL = url
    let raw = try Data(contentsOf: url)
    let xmlData = try Gzip.inflate(raw)
    // Preserve whitespace/quoting so untouched nodes serialize back faithfully.
    let doc = try XMLDocument(data: xmlData, options: [.nodePreserveAll])
    guard let root = doc.rootElement() else {
      throw AlsError.notALiveSet
    }
    self.xml = doc
    self.root = root
  }

  /// Serialize the (possibly edited) tree back to gzipped `.als` bytes.
  func serialized() throws -> Data {
    let xmlData = xml.xmlData(options: [.nodePreserveAll])
    return try Gzip.deflate(xmlData)
  }

  func save(to destination: URL) throws {
    try serialized().write(to: destination)
  }
}

enum AlsError: Error, CustomStringConvertible {
  case notALiveSet
  var description: String {
    switch self {
    case .notALiveSet: return "This file doesn't look like an Ableton Live Set."
    }
  }
}

// MARK: - XMLElement conveniences

extension XMLElement {
  /// Direct child elements (skips text/whitespace nodes).
  var childElements: [XMLElement] {
    (children ?? []).compactMap { $0 as? XMLElement }
  }

  /// The first direct child element with the given name.
  func firstChild(_ name: String) -> XMLElement? {
    elements(forName: name).first
  }

  /// The `Value` attribute of the first direct child named `name`.
  func childValue(_ name: String) -> String? {
    firstChild(name)?.attribute(forName: "Value")?.stringValue
  }

  /// This element's own `Value` attribute.
  var valueAttr: String? {
    attribute(forName: "Value")?.stringValue
  }
}
