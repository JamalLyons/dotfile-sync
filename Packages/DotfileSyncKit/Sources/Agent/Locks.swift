// Port of crates/dotfilesync-daemon/src/locks.rs: per-resource shared/exclusive locks.
//
// Reads (scan/status/plan) take shared locks and run concurrently. Mutations take exclusive
// locks, which wait only for holders of the *same* resource. A request for several resources
// is granted all-or-nothing under one mutex, so lock ordering cannot deadlock.

import Core
import Foundation
import System

/// Lock mode for one resource.
public enum LockMode: Sendable, Equatable {
    case shared
    case exclusive
}

/// Resource identifiers. Coarse and typed rather than free-form.
public enum ResourceKey: Sendable, Hashable, Comparable {
    case homebrew
    case manifest(FilePath)
    /// The home directory an apply run mutates. Never taken from a free-form string.
    case home(FilePath)
    /// Test-only resources. Never derived from client-supplied strings.
    case named(String)

    static func manifestPath(_ path: FilePath) -> ResourceKey {
        .manifest((try? canonicalize(path)) ?? path.lexicallyNormalized())
    }

    static func homeDirectory(_ path: FilePath) -> ResourceKey {
        .home((try? canonicalize(path)) ?? path.lexicallyNormalized())
    }

    private var order: (Int, String) {
        switch self {
        case .homebrew: return (0, "")
        case let .manifest(p): return (1, p.string)
        case let .home(p): return (2, p.string)
        case let .named(n): return (3, n)
        }
    }

    public static func < (lhs: ResourceKey, rhs: ResourceKey) -> Bool {
        lhs.order < rhs.order
    }
}

/// Returned when a lock wait was abandoned because the cancellation check returned true.
public struct LockCancelled: Error, Sendable, Equatable {}

/// A blocking mutex + condition variable holding `State`.
///
/// `@unchecked Sendable`: `state` is only read or written between `condition.lock()` and
/// `condition.unlock()` (see `withLock(_:)` and `waitUntil(deadline:slice:_:onTimeout:)`).
final class Monitor<State>: @unchecked Sendable {
    private let condition = NSCondition()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        condition.lock()
        defer { condition.unlock() }
        return try body(&state)
    }

    /// Locks, then repeatedly calls `body` until it returns non-nil, waiting on the condition
    /// (at most until `deadline`, re-checking every `slice`) in between. Returns `body`'s value,
    /// or `onTimeout`'s once the deadline passes.
    func waitUntil<R>(
        deadline: ContinuousClock.Instant?,
        slice: Duration? = nil,
        _ body: (inout State) -> R?,
        onTimeout: (inout State) -> R
    ) -> R {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let result = body(&state) {
                return result
            }
            let now = ContinuousClock.now
            var wait: Duration?
            if let deadline {
                if now >= deadline {
                    return onTimeout(&state)
                }
                wait = deadline - now
            }
            if let slice {
                wait = min(wait ?? slice, slice)
            }
            if let wait {
                let (s, atto) = wait.components
                let seconds = Double(s) + Double(atto) / 1e18
                _ = condition.wait(until: Date(timeIntervalSinceNow: seconds))
            } else {
                condition.wait()
            }
        }
    }

    func broadcast() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

private struct Entry {
    var readers = 0
    var writer = false
    var waitingWriters = 0
}

/// Shared/exclusive locks keyed by ``ResourceKey`` with writer preference.
public final class ResourceLocks: Sendable {
    private let monitor = Monitor<[ResourceKey: Entry]>([:])

    public init() {}

    private static func grantable(_ entries: [ResourceKey: Entry], _ reqs: [(ResourceKey, LockMode)]) -> Bool {
        reqs.allSatisfy { key, mode in
            guard let e = entries[key] else { return true }
            switch mode {
            // Writer preference: new readers queue behind a waiting writer.
            case .shared: return !e.writer && e.waitingWriters == 0
            case .exclusive: return !e.writer && e.readers == 0
            }
        }
    }

    /// Blocks until every requested lock can be granted, or `cancelled()` returns true
    /// (checked at least every 50 ms).
    public func acquire(
        _ requests: [(ResourceKey, LockMode)],
        cancelled: () -> Bool = { false }
    ) throws(LockCancelled) -> LockGuard {
        var reqs: [(ResourceKey, LockMode)] = []
        for (key, mode) in requests.sorted(by: { $0.0 < $1.0 }) {
            if let last = reqs.last, last.0 == key {
                if mode == .exclusive {
                    reqs[reqs.count - 1].1 = .exclusive
                }
            } else {
                reqs.append((key, mode))
            }
        }
        var registered = false
        let granted: Bool = monitor.waitUntil(deadline: nil, slice: .milliseconds(50), { entries in
            // A request only registers waits on its exclusive keys, and exclusive checks ignore
            // `waitingWriters`, so a waiting request never blocks itself.
            if Self.grantable(entries, reqs) {
                if registered {
                    Self.unregisterWait(&entries, reqs)
                }
                for (key, mode) in reqs {
                    var e = entries[key] ?? Entry()
                    switch mode {
                    case .shared: e.readers += 1
                    case .exclusive: e.writer = true
                    }
                    entries[key] = e
                }
                return true
            }
            if cancelled() {
                if registered {
                    Self.unregisterWait(&entries, reqs)
                }
                return false
            }
            if !registered {
                for (key, mode) in reqs where mode == .exclusive {
                    var e = entries[key] ?? Entry()
                    e.waitingWriters += 1
                    entries[key] = e
                }
                registered = true
            }
            return nil
        }, onTimeout: { _ in false })
        if !granted {
            if registered {
                monitor.broadcast()
            }
            throw LockCancelled()
        }
        return LockGuard(locks: self, held: reqs)
    }

    private static func unregisterWait(_ entries: inout [ResourceKey: Entry], _ reqs: [(ResourceKey, LockMode)]) {
        for (key, mode) in reqs where mode == .exclusive {
            if var e = entries[key] {
                e.waitingWriters = max(0, e.waitingWriters - 1)
                entries[key] = e
            }
        }
    }

    fileprivate func release(_ held: [(ResourceKey, LockMode)]) {
        monitor.withLock { entries in
            for (key, mode) in held {
                guard var e = entries[key] else { continue }
                switch mode {
                case .shared: e.readers = max(0, e.readers - 1)
                case .exclusive: e.writer = false
                }
                if e.readers == 0 && !e.writer && e.waitingWriters == 0 {
                    entries.removeValue(forKey: key)
                } else {
                    entries[key] = e
                }
            }
        }
        monitor.broadcast()
    }

    /// Holders of `key` as `(readers, writer)` — for diagnostics and tests.
    public func holders(_ key: ResourceKey) -> (readers: Int, writer: Bool) {
        monitor.withLock { entries in
            let e = entries[key]
            return (e?.readers ?? 0, e?.writer ?? false)
        }
    }
}

/// Granted locks. Call ``release()`` when done; `deinit` releases as a fallback (Swift may end
/// an unused binding's lifetime early, so do not rely on scope end alone).
public final class LockGuard: Sendable {
    private let locks: ResourceLocks
    private let held: [(ResourceKey, LockMode)]
    private let released = Monitor(false)

    // `held` is an immutable array of Sendable values; tuples of Sendable are Sendable.
    fileprivate init(locks: ResourceLocks, held: [(ResourceKey, LockMode)]) {
        self.locks = locks
        self.held = held
    }

    /// Releases every held lock. Idempotent.
    public func release() {
        let first = released.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first {
            locks.release(held)
        }
    }

    deinit {
        release()
    }
}
