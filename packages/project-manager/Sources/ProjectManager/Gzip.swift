import CGzip
import Foundation

enum GzipError: Error { case inflateFailed, deflateFailed }

/// gzip (de)compression backed by the system zlib (see the CGzip C shim).
enum Gzip {
  static func inflate(_ data: Data) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var outPtr: UnsafeMutablePointer<UInt8>?
    var outLen = 0
    let rc = data.withUnsafeBytes { raw -> Int32 in
      let base = raw.bindMemory(to: UInt8.self).baseAddress
      return cgzip_inflate(base, data.count, &outPtr, &outLen)
    }
    guard rc == 0, let outPtr else { throw GzipError.inflateFailed }
    defer { free(outPtr) }
    return Data(bytes: outPtr, count: outLen)
  }

  static func deflate(_ data: Data) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var outPtr: UnsafeMutablePointer<UInt8>?
    var outLen = 0
    let rc = data.withUnsafeBytes { raw -> Int32 in
      let base = raw.bindMemory(to: UInt8.self).baseAddress
      return cgzip_deflate(base, data.count, &outPtr, &outLen)
    }
    guard rc == 0, let outPtr else { throw GzipError.deflateFailed }
    defer { free(outPtr) }
    return Data(bytes: outPtr, count: outLen)
  }
}
