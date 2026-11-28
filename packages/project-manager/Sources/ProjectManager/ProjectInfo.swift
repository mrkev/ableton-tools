import Foundation

/// What Live records about a project when it's first created, in
/// `Ableton Project Info/Project8_1.cfg`. It describes the project's beginning, not
/// its sets now or its files on disk.
///
/// The file is Live's binary config format: after a header, a count and a table of
/// fields (a UTF-16 name and a type byte each), then each field's value in order.
/// Type 0x11 is a 32-bit little-endian integer, 0x14 a string (a 32-bit count of
/// UTF-16 units, then the units). Files written by Live 8 add a file reference (type
/// 0x00, an object whose class name follows the type byte), whose value isn't read;
/// the creator version after it is read back from the end (see `parse`).
struct ProjectInfo: Hashable {
  /// `CreationDate`, seconds since 1970.
  var created: Date?
  /// `CreatorVersion`: "9.6.1 Build: 2016-03-24_3f5b61a842".
  var creatorVersion: String?

  /// "9.6.1", the Live that created the project.
  var creatorLive: String? { creatorVersion?.split(separator: " ").first.map(String.init) }

  static let fileName = "Project8_1.cfg"

  init?(projectFolder: URL) {
    let file = projectFolder.appendingPathComponent("Ableton Project Info").appendingPathComponent(Self.fileName)
    guard let data = try? Data(contentsOf: file), let info = Self.parse([UInt8](data)) else { return nil }
    self = info
  }

  init(created: Date?, creatorVersion: String?) {
    self.created = created
    self.creatorVersion = creatorVersion
  }

  static func parse(_ bytes: [UInt8]) -> ProjectInfo? {
    var reader = Reader(bytes: bytes)
    // The field table starts with its count, then the first name's length.
    guard let first = bytes.firstRange(of: Array("CreationDate".utf16LEBytes)), first.lowerBound >= 8 else { return nil }
    reader.offset = first.lowerBound - 8
    guard let count = reader.uint32(), count < 64 else { return nil }
    var fields: [(name: String, type: UInt8)] = []
    for _ in 0..<count {
      guard let name = reader.string(), let type = reader.byte() else { return nil }
      // An object field (Live 8's file reference) names its class: "Slot<FileRef>".
      if type == 0x00 {
        guard let length = reader.byte(), reader.skip(Int(length)) else { return nil }
      }
      fields.append((name, type))
    }
    var values: [String: Any] = [:]
    for field in fields {
      switch field.type {
      case 0x11: guard let v = reader.uint32() else { break }; values[field.name] = Int32(bitPattern: v)
      case 0x14: guard let v = reader.string() else { break }; values[field.name] = v
      default: break
      }
      if field.type != 0x11 && field.type != 0x14 { break }
    }
    var info = ProjectInfo(created: (values["CreationDate"] as? Int32).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                           creatorVersion: values["CreatorVersion"] as? String)
    // Past a field of an unread type, the last field, a string, can still be read
    // back from the end of the file.
    if info.creatorVersion == nil, fields.last?.name == "CreatorVersion", fields.last?.type == 0x14 {
      info.creatorVersion = Reader.trailingString(bytes)
    }
    return info.created == nil && info.creatorVersion == nil ? nil : info
  }

  private struct Reader {
    let bytes: [UInt8]
    var offset = 0

    mutating func byte() -> UInt8? {
      guard offset < bytes.count else { return nil }
      defer { offset += 1 }
      return bytes[offset]
    }

    mutating func skip(_ count: Int) -> Bool {
      guard offset + count <= bytes.count else { return false }
      offset += count
      return true
    }

    mutating func uint32() -> UInt32? {
      guard offset + 4 <= bytes.count else { return nil }
      defer { offset += 4 }
      return bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A 32-bit count of UTF-16 units, then the units.
    mutating func string() -> String? {
      guard let units = uint32(), units < 4096, offset + Int(units) * 2 <= bytes.count else { return nil }
      let slice = bytes[offset..<offset + Int(units) * 2]
      offset += Int(units) * 2
      return String(decoding: stride(from: slice.startIndex, to: slice.endIndex, by: 2).map {
        UInt16(slice[$0]) | UInt16(slice[$0 + 1]) << 8
      }, as: UTF16.self)
    }

    /// The string that ends the file: the count before it matches its length.
    static func trailingString(_ bytes: [UInt8]) -> String? {
      for units in 1...200 {
        let start = bytes.count - units * 2 - 4
        guard start >= 0 else { return nil }
        var check = Reader(bytes: bytes, offset: start)
        guard check.uint32() == UInt32(units) else { continue }
        var reader = Reader(bytes: bytes, offset: start)
        return reader.string()
      }
      return nil
    }
  }
}

private extension String {
  var utf16LEBytes: [UInt8] { utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }
}
