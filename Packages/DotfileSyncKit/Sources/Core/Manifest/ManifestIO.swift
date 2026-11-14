// Port of the functions in crates/dotfilesync-core/src/manifest/mod.rs:
// parse/load/serialize plus manifest path encoding and expansion.

import Foundation
import System
import TOMLKit

/// Parses TOML text into a ``Manifest`` and validates it.
///
/// Unknown keys are ignored, as with serde's default. Validation failures become
/// ``ManifestError/validation(_:_:)`` with each message on its own `- ` line.
public func parseManifest(_ content: String) throws(ManifestError) -> Manifest {
    let manifest: Manifest
    do {
        manifest = try TOMLDecoder().decode(Manifest.self, from: content)
    } catch let error as TOMLParseError {
        throw .parse(error.debugDescription)
    } catch {
        throw .parse(String(describing: error))
    }
    let errors = validateManifest(manifest)
    if !errors.isEmpty {
        let message = errors.map { "- \($0)" }.joined(separator: "\n")
        throw .validation(errors.count, message)
    }
    return manifest
}

/// Loads and validates a manifest from disk.
///
/// Manifest files must be UTF-8 text per the TOML specification; non-UTF-8 content is rejected
/// with ``ManifestError/io(path:reason:)`` (`stream did not contain valid UTF-8`, the Rust
/// `InvalidData` message).
public func loadManifest(_ path: String) throws(ManifestError) -> Manifest {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw .io(path: path, reason: ioReason(error))
    }
    guard let content = String(validating: data, as: UTF8.self) else {
        throw .io(path: path, reason: "stream did not contain valid UTF-8")
    }
    return try parseManifest(content)
}

/// Loads and validates a manifest from a file URL. See ``loadManifest(_:)-(String)``.
public func loadManifest(_ url: URL) throws(ManifestError) -> Manifest {
    try loadManifest(url.path)
}

/// Encodes `manifest` as TOML.
///
/// Key order and layout follow TOMLKit, not the Rust `toml` crate's pretty printer, so the
/// text differs from Rust output; the parsed value round-trips.
public func serializeManifest(_ manifest: Manifest) throws(ManifestError) -> String {
    do {
        let encoded: String = try TOMLEncoder().encode(manifest)
        return encoded
    } catch {
        throw .serialize(String(describing: error))
    }
}

/// Decodes a manifest path string into native path bytes.
///
/// Standard UTF-8 paths are preserved. Percent-encoded byte sequences (e.g. `%FF` or `%fe`)
/// are decoded into raw bytes, so manifests can name non-UTF-8 paths while staying valid TOML.
public func decodeManifestPathBytes(_ pathString: String) -> FilePath {
    let bytes = Array(pathString.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        // Matches Rust's `i + 2 < len`: a `%HH` that ends the string is kept literally.
        if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
           let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
            decoded.append((high << 4) | low)
            i += 3
            continue
        }
        decoded.append(bytes[i])
        i += 1
    }
    return filePath(fromBytes: decoded)
}

/// Encodes a native filesystem path into a valid UTF-8 manifest path string.
///
/// Valid UTF-8 is returned as-is; every byte that is not part of a well-formed UTF-8 sequence
/// is percent-encoded as `%HH` (uppercase), so no replacement characters are introduced.
public func encodeManifestPathBytes(_ path: FilePath) -> String {
    let bytes = pathBytes(path)
    if let valid = String(validating: bytes, as: UTF8.self) {
        return valid
    }
    var encoded = ""
    var i = 0
    while i < bytes.count {
        let width = validScalarWidth(bytes, at: i)
        if width > 0 {
            encoded += String(decoding: bytes[i..<(i + width)], as: UTF8.self)
            i += width
        } else {
            encoded += "%" + hexByte(bytes[i])
            i += 1
        }
    }
    return encoded
}

/// Expands a leading `~` against `homeDir`.
///
/// Non-UTF-8 bytes in `homeDir` are preserved; `%HH` sequences in `target` are decoded.
/// An absolute remainder replaces `homeDir`, as Rust `Path::join` does.
public func expandTargetPath(_ target: String, homeDir: FilePath) -> FilePath {
    if target.hasPrefix("~/") {
        return homeDir.pushing(decodeManifestPathBytes(String(target.dropFirst(2))))
    } else if target == "~" {
        return homeDir
    } else {
        return decodeManifestPathBytes(target)
    }
}

/// Resolves a source path relative to the repository / manifest base directory.
///
/// Non-UTF-8 bytes in `baseDir` are preserved; `%HH` sequences in `source` are decoded.
public func resolveSourcePath(_ source: String, baseDir: FilePath) -> FilePath {
    baseDir.pushing(decodeManifestPathBytes(source))
}

// MARK: - Helpers

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
}

private func hexByte(_ byte: UInt8) -> String {
    let digits = Array("0123456789ABCDEF")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
}

/// Width of the well-formed UTF-8 scalar starting at `i` (Unicode Table 3-7), or 0.
private func validScalarWidth(_ bytes: [UInt8], at i: Int) -> Int {
    let b0 = bytes[i]
    func cont(_ offset: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
        i + offset < bytes.count && range.contains(bytes[i + offset])
    }
    switch b0 {
    case 0x00...0x7F: return 1
    case 0xC2...0xDF: return cont(1) ? 2 : 0
    case 0xE0: return cont(1, 0xA0...0xBF) && cont(2) ? 3 : 0
    case 0xE1...0xEC, 0xEE...0xEF: return cont(1) && cont(2) ? 3 : 0
    case 0xED: return cont(1, 0x80...0x9F) && cont(2) ? 3 : 0
    case 0xF0: return cont(1, 0x90...0xBF) && cont(2) && cont(3) ? 4 : 0
    case 0xF1...0xF3: return cont(1) && cont(2) && cont(3) ? 4 : 0
    case 0xF4: return cont(1, 0x80...0x8F) && cont(2) && cont(3) ? 4 : 0
    default: return 0
    }
}

func filePath(fromBytes bytes: [UInt8]) -> FilePath {
    var cString = bytes.map { CChar(bitPattern: $0) }
    cString.append(0)
    return cString.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return FilePath() }
        return FilePath(platformString: base)
    }
}

func pathBytes(_ path: FilePath) -> [UInt8] {
    path.withPlatformString { pointer in
        var bytes: [UInt8] = []
        var cursor = pointer
        while cursor.pointee != 0 {
            bytes.append(UInt8(bitPattern: cursor.pointee))
            cursor += 1
        }
        return bytes
    }
}

/// Rust `io::Error` display for OS errors: `<strerror> (os error <errno>)`.
private func ioReason(_ error: any Error) -> String {
    let nsError = error as NSError
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
       underlying.domain == NSPOSIXErrorDomain {
        return posixReason(Int32(underlying.code))
    }
    if nsError.domain == NSPOSIXErrorDomain {
        return posixReason(Int32(nsError.code))
    }
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
        return posixReason(ENOENT)
    }
    return nsError.localizedDescription
}

private func posixReason(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (os error \(code))"
}
