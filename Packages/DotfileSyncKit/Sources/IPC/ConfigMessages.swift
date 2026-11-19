import Core
import Foundation

/// An editable UTF-8 snapshot or a view-only binary snapshot.
public struct ConfigDocument: Codable, Sendable, Equatable {
    public let path: String
    public let text: String?
    public let bytesBase64: String?
    public let isBinary: Bool
    public let mode: UInt32
    public let version: FileVersion

    public init(_ document: EditorDocument) {
        path = document.path.string
        text = document.text
        bytesBase64 = document.isBinary ? Data(document.bytes).base64EncodedString() : nil
        isBinary = document.isBinary
        mode = document.mode
        version = document.version
    }

    private enum CodingKeys: String, CodingKey {
        case path, text, mode, version
        case bytesBase64 = "bytes_base64"
        case isBinary = "is_binary"
    }
}

/// The destination, its new version, and the backup path when previous contents were replaced.
public struct ConfigWriteReport: Codable, Sendable, Equatable {
    public let path: String
    public let backupPath: String?
    public let newVersion: FileVersion

    public init(_ report: EditorWriteReport) {
        path = report.path.string
        backupPath = report.backupPath?.string
        newVersion = report.newVersion
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case backupPath = "backup_path"
        case newVersion = "new_version"
    }
}
