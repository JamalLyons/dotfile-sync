// Port of crates/dotfilesync-core/src/manifest/validation.rs.

import Foundation

/// Substrings that mark a tracked source or target as a credential store.
let sensitivePathPatterns: [String] = [
    ".ssh",
    "id_rsa",
    "id_ed25519",
    "id_ecdsa",
    "id_dsa",
    ".aws/credentials",
    ".gnupg",
    ".docker/config.json",
    "keychain",
    "credentials.json",
]

/// Checks schema version, tracked files (base and per profile), profile references, and
/// exclusion glob syntax. Returns every problem found, in the same order as Rust; an empty
/// array means the manifest is valid (Rust returns `Result<(), Vec<ValidationError>>`, which
/// Swift cannot express because an array is not an `Error`).
public func validateManifest(_ manifest: Manifest) -> [ValidationError] {
    var errors: [ValidationError] = []

    if manifest.schemaVersion != CURRENT_SCHEMA_VERSION {
        errors.append(.unsupportedSchemaVersion(
            version: manifest.schemaVersion,
            expected: CURRENT_SCHEMA_VERSION
        ))
    }

    validateFiles(manifest.files, into: &errors)
    for name in manifest.profiles.keys.sorted(by: byteOrderPrecedes) {
        if let profile = manifest.profiles[name] {
            validateFiles(profile.files, into: &errors)
        }
    }
    errors.append(contentsOf: profileValidationErrors(manifest))

    for pattern in manifest.exclusions.patterns {
        if let reason = GlobSyntax.error(in: pattern) {
            errors.append(.invalidExclusionPattern(pattern: pattern, reason: reason))
        }
    }

    return errors
}

private func validateFiles(_ files: [TrackedFile], into errors: inout [ValidationError]) {
    var seenTargets = Set<String>()

    for file in files {
        if rustTrim(file.source).isEmpty {
            errors.append(.emptySourcePath(target: file.target))
        } else if file.source.hasPrefix("/") {
            errors.append(.absoluteSourcePath(sourcePath: file.source))
        }

        if rustTrim(file.target).isEmpty {
            errors.append(.emptyTargetPath(sourcePath: file.source))
        }

        // `Path::components()` yields `ParentDir` exactly for `..` segments.
        if file.source.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
            errors.append(.illegalPathTraversal(sourcePath: file.source))
        }

        if !seenTargets.insert(rustTrim(file.target)).inserted {
            errors.append(.duplicateTargetPath(target: file.target))
        }

        for sensitive in sensitivePathPatterns
        where file.target.contains(sensitive) || file.source.contains(sensitive) {
            errors.append(.sensitiveCredentialPath(path: file.target))
            break
        }
    }
}

/// Rust `str::trim`: strips Unicode `White_Space` from both ends.
func rustTrim(_ value: String) -> String {
    var scalars = Substring(value).unicodeScalars
    while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
    while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
    return String(scalars)
}

/// Syntax check that mirrors `glob::Pattern::new` from the `glob` crate (0.3.4, the version
/// pinned in Cargo.lock), including its error positions and messages.
enum GlobSyntax {
    private static let errorWildcards = "wildcards are either regular `*` or recursive `**`"
    private static let errorRecursiveWildcards = "recursive wildcards must form a single path component"
    private static let errorInvalidRange = "invalid range pattern"

    /// The `PatternError` display string, or `nil` when `pattern` compiles.
    static func error(in pattern: String) -> String? {
        let chars = Array(pattern.unicodeScalars)
        var i = 0

        func failure(_ pos: Int, _ msg: String) -> String {
            "Pattern syntax error near position \(pos): \(msg)"
        }

        while i < chars.count {
            switch chars[i] {
            case "*":
                let old = i
                while i < chars.count, chars[i] == "*" {
                    i += 1
                }
                let count = i - old
                if count > 2 {
                    return failure(old + 2, errorWildcards)
                } else if count == 2 {
                    if i == 2 || chars[i - count - 1] == "/" {
                        if i < chars.count, chars[i] == "/" {
                            i += 1
                        } else if i == chars.count {
                            // Pattern ends with `**`.
                        } else {
                            return failure(i, errorRecursiveWildcards)
                        }
                    } else {
                        return failure(old - 1, errorRecursiveWildcards)
                    }
                }
            case "[":
                if i + 4 <= chars.count, chars[i + 1] == "!" {
                    if let j = chars[(i + 3)...].firstIndex(of: "]") {
                        i = j + 1
                        continue
                    }
                } else if i + 3 <= chars.count, chars[i + 1] != "!" {
                    if let j = chars[(i + 2)...].firstIndex(of: "]") {
                        i = j + 1
                        continue
                    }
                }
                return failure(i, errorInvalidRange)
            default:
                i += 1
            }
        }
        return nil
    }
}
