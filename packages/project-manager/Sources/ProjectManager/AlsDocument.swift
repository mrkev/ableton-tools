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
  /// The source's bytes before `<Ableton` and after `</Ableton>`, restored on save.
  private let prolog: Data
  private let epilog: Data

  /// Whitespace Live escapes in attributes (`Annotation` line breaks). XMLDocument
  /// serializes these as raw characters, which parsers read back as spaces, so
  /// they travel through the DOM as private-use characters instead.
  private static let escapedWhitespace: [(entity: Data, placeholder: Data, utf8: Data)] =
    [("0A", "F00A"), ("09", "F009"), ("0D", "F00D")].map { code, private_ in
      (Data("&#x\(code);".utf8), Data("&#x\(private_);".utf8),
       Data(String(UnicodeScalar(UInt32(private_, radix: 16)!)!).utf8))
    }
  private static let rootTag = Data("<Ableton".utf8)
  private static let rootEnd = Data("</Ableton>".utf8)

  init(url: URL) throws {
    self.sourceURL = url
    let raw = try Data(contentsOf: url)
    var xmlData = try Gzip.inflate(raw)
    guard let rootStart = xmlData.offset(of: Self.rootTag) else { throw AlsError.notALiveSet }
    self.prolog = xmlData.prefix(rootStart)
    self.epilog = xmlData.lastOffset(of: Self.rootEnd).map { xmlData.suffix(from: xmlData.startIndex + $0 + Self.rootEnd.count) }
      .map { Data($0) } ?? Data()
    for w in Self.escapedWhitespace { xmlData = xmlData.replacingBytes(w.entity, with: w.placeholder) }
    // Preserve whitespace/quoting so untouched nodes serialize back faithfully.
    let doc = try XMLDocument(data: xmlData, options: [.nodePreserveAll])
    guard let root = doc.rootElement() else {
      throw AlsError.notALiveSet
    }
    self.xml = doc
    self.root = root
  }

  /// e.g. "Ableton Live 10.1.40".
  var creator: String { root.attribute(forName: "Creator")?.stringValue ?? "" }

  var predatesVst3: Bool { LiveVersion.predatesVst3(creator: creator) }

  /// `AutomationTarget` ids that have envelopes somewhere in the set.
  var automatedTargetIds: Set<String> {
    Set((try? root.nodes(forXPath: "//PointeeId/@Value"))?.compactMap(\.stringValue) ?? [])
  }

  /// Serialize the (possibly edited) tree back to gzipped `.als` bytes.
  func serialized() throws -> Data {
    var xmlData = xml.xmlData(options: [.nodePreserveAll])
    for w in Self.escapedWhitespace { xmlData = xmlData.replacingBytes(w.utf8, with: w.entity) }
    if let rootStart = xmlData.offset(of: Self.rootTag) {
      xmlData.replaceSubrange(xmlData.startIndex..<(xmlData.startIndex + rootStart), with: prolog)
    }
    if let end = xmlData.lastOffset(of: Self.rootEnd) {
      xmlData.replaceSubrange((xmlData.startIndex + end + Self.rootEnd.count)..., with: epilog)
    }
    return try Gzip.deflate(xmlData)
  }

  func save(to destination: URL) throws {
    try serialized().write(to: destination, options: .atomic)
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

private extension Data {
  /// Offset of `target` at or after `from`. `Data.firstRange(of:)` is far too slow
  /// for documents this size.
  func offset(of target: Data, from: Int = 0) -> Int? {
    withUnsafeBytes { (haystack: UnsafeRawBufferPointer) -> Int? in
      target.withUnsafeBytes { (needle: UnsafeRawBufferPointer) -> Int? in
        guard let base = haystack.baseAddress, from < haystack.count else { return nil }
        return memmem(base + from, haystack.count - from, needle.baseAddress!, needle.count)
          .map { UnsafeRawPointer($0) - base }
      }
    }
  }

  /// Offset of the last `target`, searching back from the end (it's near the end).
  func lastOffset(of target: Data) -> Int? {
    var from = Swift.max(0, count - 4096)
    while true {
      if let hit = offset(of: target, from: from) {
        var last = hit
        while let next = offset(of: target, from: last + 1) { last = next }
        return last
      }
      guard from > 0 else { return nil }
      from = Swift.max(0, from - 1 << 20)
    }
  }

  func replacingBytes(_ target: Data, with replacement: Data) -> Data {
    guard var hit = offset(of: target) else { return self }
    var out = Data()
    out.reserveCapacity(count)
    var cursor = 0
    while true {
      out.append(self[(startIndex + cursor)..<(startIndex + hit)])
      out.append(replacement)
      cursor = hit + target.count
      guard let next = offset(of: target, from: cursor) else { break }
      hit = next
    }
    out.append(self[(startIndex + cursor)...])
    return out
  }
}

// MARK: - XMLElement conveniences

extension XMLElement {
  /// A new element from text, quoted as written. Attributes made through
  /// `XMLNode` serialize single-quoted, which Live never writes.
  static func parsed(_ xml: String) throws -> XMLElement {
    let doc = try XMLDocument(xmlString: xml, options: [.nodePreserveAll])
    guard let root = doc.rootElement() else { throw AlsError.notALiveSet }
    root.detach()
    return root
  }

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
