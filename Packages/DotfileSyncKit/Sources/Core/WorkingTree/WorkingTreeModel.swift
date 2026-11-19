/// Working-tree status of a configuration file.
public enum WorkingTreeStatus: String, Codable, Sendable, Equatable {
    case managed
    case modified
    case unmanaged
    case excluded
}

/// Counts of file statuses in a directory subtree.
public struct WorkingTreeCounts: Codable, Sendable, Equatable {
    public internal(set) var managed = 0
    public internal(set) var modified = 0
    public internal(set) var unmanaged = 0
    public internal(set) var excluded = 0

    mutating func count(_ status: WorkingTreeStatus) {
        switch status {
        case .managed: managed += 1
        case .modified: modified += 1
        case .unmanaged: unmanaged += 1
        case .excluded: excluded += 1
        }
    }

    mutating func add(_ other: WorkingTreeCounts) {
        managed += other.managed
        modified += other.modified
        unmanaged += other.unmanaged
        excluded += other.excluded
    }
}

public struct WorkingTreeNode: Codable, Sendable, Equatable {
    public let relativePath: String
    public let kind: DiscoveredEntryKind
    public let status: WorkingTreeStatus?
    public let `class`: ConfigClass
    public let language: ConfigLanguage?
    public let tool: String?
    /// The source as written in the resolved manifest.
    public let managedSource: String?
    public let excludedReason: String?
    /// Present on directories, including empty ones.
    public let aggregate: WorkingTreeCounts?
    public let children: [WorkingTreeNode]?

    private enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case kind, status, `class`, language, tool
        case managedSource = "managed_source"
        case excludedReason = "excluded_reason"
        case aggregate, children
    }
}

public struct WorkingTree: Codable, Sendable, Equatable {
    /// Represents HOME with an empty relative path.
    public let root: WorkingTreeNode
    /// Whether discovery hit a limit. All in-HOME manifest entries are still represented.
    public let truncated: Bool
    public let diagnostics: [Diagnostic]
}

public enum ConfigFileDiffStatus: String, Codable, Sendable, Equatable {
    case unchanged
    case changed
    /// No managed entry, or its repository source is missing.
    case noBase = "no_base"
    case binary
    case tooLarge = "too_large"
    /// Computing the line diff would exceed the work limit.
    case tooComplex = "too_complex"
}

public struct ConfigDiffHunk: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// Unified diff lines, including their prefixes and any missing-newline markers.
    public let lines: [String]

    private enum CodingKeys: String, CodingKey {
        case oldStart = "old_start"
        case oldCount = "old_count"
        case newStart = "new_start"
        case newCount = "new_count"
        case lines
    }

    fileprivate var header: String {
        let old = oldCount == 1 ? "\(oldStart)" : "\(oldStart),\(oldCount)"
        let new = newCount == 1 ? "\(newStart)" : "\(newStart),\(newCount)"
        return "@@ -\(old) +\(new) @@"
    }
}

public struct ConfigFileDiff: Codable, Sendable, Equatable {
    public let relativePath: String
    public let managedSource: String?
    public let status: ConfigFileDiffStatus
    /// Whether this diff represents a deletion from the machine.
    public let targetMissing: Bool
    public let additions: Int
    public let deletions: Int
    public let hunks: [ConfigDiffHunk]

    private enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case managedSource = "managed_source"
        case status
        case targetMissing = "target_missing"
        case additions, deletions, hunks
    }

    /// Renders the wire model as unified diff text for a changed file.
    public var unifiedDiff: String? {
        guard status == .changed else { return nil }
        let old = diffHeaderPath("a/" + relativePath)
        let new = targetMissing ? "/dev/null" : diffHeaderPath("b/" + relativePath)
        var text = "--- \(old)\n+++ \(new)\n"
        for hunk in hunks {
            text += hunk.header + "\n"
            for line in hunk.lines { text += line + "\n" }
        }
        return text
    }
}

private func diffHeaderPath(_ path: String) -> String {
    guard path.utf8.contains(where: { $0 < 32 || $0 == 127 || $0 == 34 || $0 == 92 }) else { return path }
    return "\"" + path.utf8.map { byte in
        switch byte {
        case 34: return "\\\""
        case 92: return "\\\\"
        case 0..<32, 127...255:
            let octal = String(byte, radix: 8)
            return "\\" + String(repeating: "0", count: 3 - octal.count) + octal
        default: return String(Unicode.Scalar(byte))
        }
    }.joined() + "\""
}

public enum WorkingTreeError: Error, Codable, Sendable, Equatable {
    case excluded
    case invalidTarget
    case invalidByteLimit
    /// An unconfined path, unsupported symlink, or non-regular file.
    case unsafePath
    case io(message: String)

    private enum CodingKeys: String, CodingKey {
        case excluded
        case invalidTarget = "invalid_target"
        case invalidByteLimit = "invalid_byte_limit"
        case unsafePath = "unsafe_path"
        case io
    }
}
