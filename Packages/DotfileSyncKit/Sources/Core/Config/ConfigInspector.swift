// Port of crates/dotfilesync-core/src/config/inspector.rs.
//
// Filesystem access uses POSIX calls so behaviour matches Rust std exactly:
// `symlink_metadata` = lstat, `exists` = stat, `canonicalize` = realpath, `read_link` = readlink,
// `File::open` + `read` = open(O_RDONLY | O_CLOEXEC) + read. Only ENOENT counts as "not found"
// (Rust `ErrorKind::NotFound`); every other errno is reported as unreadable.

import CryptoKit
import Darwin
import System

/// An OS error, displayed like Rust `io::Error` for OS errors: `<strerror> (os error <errno>)`.
public struct OSIOError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The raw `errno` value (Rust `raw_os_error`).
    public var errno: Int32

    public init(errno: Int32) {
        self.errno = errno
    }

    public var description: String {
        "\(String(cString: strerror(errno))) (os error \(errno))"
    }

    static func current() -> OSIOError {
        OSIOError(errno: Darwin.errno)
    }
}

/// Inspects tracked files against the machine without modifying anything.
public struct ConfigInspector: Sendable {
    public var repoRoot: FilePath
    public var homeDir: FilePath
    public var exclusions: ExclusionsSection
    public var overrides: [MachineOverride]

    public init(
        repoRoot: FilePath,
        homeDir: FilePath,
        exclusions: ExclusionsSection,
        overrides: [MachineOverride]
    ) {
        self.repoRoot = repoRoot
        self.homeDir = homeDir
        self.exclusions = exclusions
        self.overrides = overrides
    }

    /// Inspects each file in order.
    public func inspectFiles(_ files: [TrackedFile]) -> [ObservedConfigFile] {
        files.map(inspectFile)
    }

    /// Classifies one tracked file. Never throws; failures become ``ConfigFileState/unreadable``
    /// (or another state) with a diagnostic.
    public func inspectFile(_ file: TrackedFile) -> ObservedConfigFile {
        let sourcePath = resolveSourcePath(file.source, baseDir: repoRoot)
        let targetPath = expandTargetPath(file.target, homeDir: homeDir)

        func result(
            _ state: ConfigFileState,
            sourceHash: String? = nil,
            targetHash: String? = nil,
            targetSize: UInt64? = nil,
            isSymlink: Bool = false,
            symlinkTarget: FilePath? = nil,
            _ diagnostic: String?
        ) -> ObservedConfigFile {
            ObservedConfigFile(
                sourcePath: sourcePath,
                targetPath: targetPath,
                state: state,
                sourceHash: sourceHash,
                targetHash: targetHash,
                targetSize: targetSize,
                isSymlink: isSymlink,
                symlinkTarget: symlinkTarget,
                diagnostic: diagnostic
            )
        }

        // 1. Exclusions
        if isExcluded(sourceRaw: file.source, targetRaw: file.target, targetPath: targetPath) {
            return result(.excluded, "Explicitly excluded in manifest")
        }

        // 2. Machine-local override
        let isOverride = file.machineLocal || overrides.contains { override in
            rustPathEqual(expandTargetPath(override.target, homeDir: homeDir), targetPath)
                || override.target == file.target
        }
        if isOverride {
            if pathExists(targetPath) {
                return result(
                    .machineLocal,
                    "Preserved as machine-local override (never read, hashed, or overwritten)"
                )
            }
            return result(.missing, "Machine-local override target is missing on machine")
        }

        // 3. Source boundaries and symlinks
        let repoRootCanonical = (try? canonicalize(repoRoot)) ?? repoRoot

        if file.source.utf8.first == UInt8(ascii: "/")
            || rustComponents(bytes: Array(file.source.utf8)).contains(.parentDir) {
            return result(
                .sourceOutsideRoot,
                "Source path is absolute or contains directory traversal ('..')"
            )
        }

        switch lstatPath(sourcePath) {
        case .success:
            break
        case let .failure(error) where error.errno == ENOENT:
            return result(.sourceMissing, "Source file does not exist in repository")
        case let .failure(error):
            let diagnostic = error.errno == EILSEQ
                ? "Cannot read source file in repository (illegal byte sequence / EILSEQ): \(error)"
                : "Cannot read source file in repository: \(error)"
            return result(.unreadable, diagnostic)
        }

        do {
            let canonicalSource = try canonicalize(sourcePath)
            if !rustPathStartsWith(canonicalSource, repoRootCanonical) {
                return result(
                    .sourceOutsideRoot,
                    "Source path escapes repository root via symlink or traversal"
                )
            }
        } catch {
            return result(.unreadable, "Failed to resolve canonical source path: \(error)")
        }

        let sourceHash: String
        do {
            sourceHash = try computeSha256(sourcePath)
        } catch {
            return result(.unreadable, "Failed to compute hash for source file: \(error)")
        }

        // 4. Target (lstat so symlinks are not traversed silently)
        let targetStat: stat
        switch lstatPath(targetPath) {
        case let .success(st):
            targetStat = st
        case let .failure(error) where error.errno == ENOENT:
            return result(.missing, sourceHash: sourceHash, "Target file does not exist on machine")
        case let .failure(error):
            let diagnostic = error.errno == EILSEQ
                ? "Cannot read target file on machine (illegal byte sequence / EILSEQ): \(error)"
                : "Cannot read target file on machine: \(error)"
            return result(.unreadable, sourceHash: sourceHash, diagnostic)
        }

        if (targetStat.st_mode & S_IFMT) == S_IFLNK {
            let linkTarget: FilePath
            do {
                linkTarget = try readLink(targetPath)
            } catch {
                return result(
                    .unreadable,
                    sourceHash: sourceHash,
                    isSymlink: true,
                    "Failed to read symlink destination: \(error)"
                )
            }

            let resolvedLink: FilePath
            if linkTarget.isAbsolute {
                resolvedLink = linkTarget
            } else {
                resolvedLink = (rustParent(targetPath) ?? FilePath("")).pushing(linkTarget)
            }

            let pointsToSource = rustPathEqual(resolvedLink, sourcePath)
                || canonicalComponents(resolvedLink) == canonicalComponents(sourcePath)

            if pointsToSource {
                return result(
                    .symlinkToSource,
                    sourceHash: sourceHash,
                    targetHash: sourceHash,
                    isSymlink: true,
                    symlinkTarget: linkTarget,
                    "Target is a symlink pointing directly to repository source"
                )
            } else if !pathExists(resolvedLink) {
                return result(
                    .brokenSymlink,
                    sourceHash: sourceHash,
                    isSymlink: true,
                    symlinkTarget: linkTarget,
                    "Target is a broken symlink (destination does not exist)"
                )
            } else {
                return result(
                    .symlinkExternal,
                    sourceHash: sourceHash,
                    isSymlink: true,
                    symlinkTarget: linkTarget,
                    "Target is a symlink pointing outside repository"
                )
            }
        }

        // Regular file comparison
        let targetSize = UInt64(clamping: targetStat.st_size)
        let targetHash: String
        do {
            targetHash = try computeSha256(targetPath)
        } catch {
            return result(
                .unreadable,
                sourceHash: sourceHash,
                targetSize: targetSize,
                "Failed to compute target file checksum: \(error)"
            )
        }

        if sourceHash == targetHash {
            return result(
                .matching, sourceHash: sourceHash, targetHash: targetHash, targetSize: targetSize, nil
            )
        }
        return result(
            .changed,
            sourceHash: sourceHash,
            targetHash: targetHash,
            targetSize: targetSize,
            "Target content differs from repository source (drift detected)"
        )
    }

    private func isExcluded(sourceRaw: String, targetRaw: String, targetPath: FilePath) -> Bool {
        let targetBytes = pathBytes(targetPath)
        for excluded in exclusions.paths {
            let expandedExcluded = expandTargetPath(excluded, homeDir: homeDir)
            if excluded == sourceRaw
                || excluded == targetRaw
                || rustPathEqual(expandedExcluded, targetPath)
                || rustPathEndsWith(bytes: targetBytes, excluded)
                || rustPathEndsWith(bytes: Array(sourceRaw.utf8), excluded) {
                return true
            }
        }

        for patternString in exclusions.patterns {
            guard let pattern = GlobPattern(patternString) else { continue }
            if pattern.matches(sourceRaw) || pattern.matches(targetRaw) {
                return true
            }
            if let name = rustFileName(targetPath),
               let fileName = String(validating: name, as: UTF8.self),
               pattern.matches(fileName) {
                return true
            }
        }
        return false
    }
}

/// Hex-encoded (lowercase) SHA-256 of the file at `path`, streamed in 8 KiB chunks.
public func computeSha256(_ path: FilePath) throws(OSIOError) -> String {
    let fd = path.withPlatformString { open($0, O_RDONLY | O_CLOEXEC) }
    if fd < 0 {
        throw OSIOError.current()
    }
    defer { close(fd) }

    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let bytesRead = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        if bytesRead < 0 {
            throw OSIOError.current()
        }
        if bytesRead == 0 {
            break
        }
        buffer.withUnsafeBytes { raw in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<bytesRead]))
        }
    }
    return hasher.finalize().map { byte in
        let hex = String(byte, radix: 16)
        return byte < 0x10 ? "0" + hex : hex
    }.joined()
}

// MARK: - POSIX helpers

/// Rust `Path::exists`: `stat` (follows symlinks) succeeds.
func pathExists(_ path: FilePath) -> Bool {
    var st = stat()
    return path.withPlatformString { stat($0, &st) } == 0
}

/// Rust `fs::symlink_metadata`.
func lstatPath(_ path: FilePath) -> Result<stat, OSIOError> {
    var st = stat()
    if path.withPlatformString({ lstat($0, &st) }) == 0 {
        return .success(st)
    }
    return .failure(OSIOError.current())
}

/// Rust `fs::canonicalize` (realpath).
func canonicalize(_ path: FilePath) throws(OSIOError) -> FilePath {
    let resolved: UnsafeMutablePointer<CChar>? = path.withPlatformString { realpath($0, nil) }
    guard let resolved else {
        throw OSIOError.current()
    }
    defer { free(resolved) }
    return FilePath(platformString: resolved)
}

/// Rust `fs::read_link`.
func readLink(_ path: FilePath) throws(OSIOError) -> FilePath {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let length = path.withPlatformString { pointer in
        buffer.withUnsafeMutableBufferPointer { readlink(pointer, $0.baseAddress, $0.count - 1) }
    }
    if length < 0 {
        throw OSIOError.current()
    }
    return filePath(fromBytes: buffer.prefix(length).map { UInt8(bitPattern: $0) })
}

/// `fs::canonicalize(path).ok()` as comparable components (`nil` on failure, like Rust).
private func canonicalComponents(_ path: FilePath) -> [RustPathComponent]? {
    guard let canonical = try? canonicalize(path) else { return nil }
    return rustComponents(canonical)
}
