// Port of crates/dotfilesync-daemon/src/log.rs: bounded, rotated, redacted agent log.

import Synchronization
import System

/// Largest single log line (bytes); longer lines are truncated.
let MAX_LOG_LINE = 2048

/// Log severity.
public enum LogLevel: String, Sendable {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// Rotating log at `path` with `keep` rotated files (`path.1` … `path.<keep>`).
///
/// Each line is `"<unix ms> <LEVEL> <redacted message>\n"`; control characters become spaces.
public final class Logger: Sendable {
    private let path: FilePath
    private let maxBytes: UInt64
    private let keep: Int

    private struct Open {
        var file: PrivateFile
        var size: UInt64
    }

    /// The open file and its size. `PrivateFile` is only touched while this mutex is held.
    private let inner: Mutex<SendableBox<Open?>>

    /// Opens (creating 0600) the log at `path`.
    public init(path: FilePath, maxBytes: UInt64, keep: Int) throws(AgentIOError) {
        let file = try openPrivateFile(path, mode: .append)
        let size = try file.size()
        self.path = path
        self.maxBytes = max(maxBytes, 256)
        self.keep = max(keep, 1)
        inner = Mutex(SendableBox(Open(file: file, size: size)))
    }

    private init() {
        path = FilePath()
        maxBytes = 0
        keep = 0
        inner = Mutex(SendableBox(nil))
    }

    /// A logger that discards everything (used when the log file cannot be opened).
    public static func disabled() -> Logger {
        Logger()
    }

    public func info(_ message: String) { write(.info, message) }
    public func warn(_ message: String) { write(.warn, message) }
    public func error(_ message: String) { write(.error, message) }

    /// Writes one line, rotating first if it would exceed the size bound.
    public func write(_ level: LogLevel, _ message: String) {
        inner.withLock { box in
            guard let current = box.value else { return }
            var clean = String(String.UnicodeScalarView(message.unicodeScalars.map { isControl($0) ? " " : $0 }))
            if clean.utf8.count > MAX_LOG_LINE {
                var out = String.UnicodeScalarView()
                var used = 0
                for scalar in clean.unicodeScalars {
                    let len = String(scalar).utf8.count
                    if used + len > MAX_LOG_LINE { break }
                    out.append(scalar)
                    used += len
                }
                clean = String(out) + " …[truncated]"
            }
            let line = Array("\(nowMs()) \(level.rawValue) \(redact(clean))\n".utf8)
            if current.size + UInt64(line.count) > maxBytes {
                box.value = rotate()
            }
            if var open = box.value {
                if (try? open.file.writeAll(line)) != nil {
                    open.size += UInt64(line.count)
                    box.value = open
                }
            }
        }
    }

    private func rotated(_ n: Int) -> FilePath {
        FilePath(path.string + ".\(n)")
    }

    private func rotate() -> Open? {
        removeFile(rotated(keep))
        if keep > 1 {
            for n in stride(from: keep - 1, through: 1, by: -1) {
                try? renamePath(rotated(n), rotated(n + 1))
            }
        }
        try? renamePath(path, rotated(1))
        guard let file = try? openPrivateFile(path, mode: .append) else { return nil }
        return Open(file: file, size: 0)
    }
}

/// Rust `char::is_control`: general category Cc.
private func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .control
}

/// Moves a non-Sendable value into a `Mutex`. Only ever accessed inside `Mutex.withLock`.
struct SendableBox<T>: @unchecked Sendable {
    // @unchecked: every SendableBox in this target lives inside a `Mutex` and is only read or
    // written from that mutex's `withLock` closure.
    var value: T

    init(_ value: T) {
        self.value = value
    }
}
