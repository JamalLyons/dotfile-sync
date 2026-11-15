// Port of crates/dotfilesync-daemon/tests/lock_approval_tests.rs.

import Agent
import Foundation
import Synchronization
import Testing

private let A = ResourceKey.named("fixture-a")
private let B = ResourceKey.named("fixture-b")

private final class Counter: Sendable {
    let inside = Atomic<Int>(0)
    let peak = Atomic<Int>(0)
}

private func spawn(_ body: @escaping @Sendable () -> Void) -> Thread {
    let t = Thread(block: body)
    t.start()
    return t
}

/// Thread-safe boolean shared with test threads.
final class Flag: Sendable {
    private let value = Atomic<Bool>(false)
    func set() { value.store(true, ordering: .sequentiallyConsistent) }
    var isSet: Bool { value.load(ordering: .sequentiallyConsistent) }
}

private final class Done: Sendable {
    let flag = Atomic<Bool>(false)
}

/// Runs a body on a thread and lets the caller join it.
private final class Joinable: Sendable {
    private let done = Done()
    init(_ body: @escaping @Sendable () -> Void) {
        let done = self.done
        _ = spawn {
            body()
            done.flag.store(true, ordering: .sequentiallyConsistent)
        }
    }

    var isFinished: Bool { done.flag.load(ordering: .sequentiallyConsistent) }

    func join(timeout: Duration = .seconds(10)) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isFinished {
            if ContinuousClock.now >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }
}

/// `n` threads each take `mode` on a key and record peak concurrency inside the section.
private func peakConcurrency(_ keys: [ResourceKey], _ mode: LockMode, _ n: Int) -> Int {
    let locks = ResourceLocks()
    let counter = Counter()
    let ready = Counter()
    let joins = (0..<n).map { i in
        let key = keys[i % keys.count]
        return Joinable {
            // Barrier.
            ready.inside.add(1, ordering: .sequentiallyConsistent)
            while ready.inside.load(ordering: .sequentiallyConsistent) < n { Thread.sleep(forTimeInterval: 0.001) }
            guard let g = try? locks.acquire([(key, mode)]) else { return }
            let now = counter.inside.add(1, ordering: .sequentiallyConsistent).newValue
            _ = counter.peak.max(now, ordering: .sequentiallyConsistent)
            Thread.sleep(forTimeInterval: 0.06)
            counter.inside.subtract(1, ordering: .sequentiallyConsistent)
            g.release()
        }
    }
    _ = joins.allSatisfy { $0.join() }
    return counter.peak.load(ordering: .sequentiallyConsistent)
}

@Suite struct LockTests {
    @Test func conflictingMutationsOnOneResourceAreSerialized() {
        #expect(peakConcurrency([A], .exclusive, 4) == 1)
    }

    @Test func mutationsOnDifferentResourcesRunConcurrently() {
        #expect(peakConcurrency([A, B], .exclusive, 2) == 2)
    }

    @Test func readsShareAResource() {
        #expect(peakConcurrency([A], .shared, 4) == 4)
    }

    @Test func writerWaitsForReadersAndNewReadersQueueBehindWriter() throws {
        let locks = ResourceLocks()
        let reader = try locks.acquire([(A, .shared)])

        let writerIn = Flag()
        let w = Joinable {
            guard let g = try? locks.acquire([(A, .exclusive)]) else { return }
            writerIn.set()
            Thread.sleep(forTimeInterval: 0.1)
            g.release()
        }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(!writerIn.isSet, "writer must wait for the reader")

        // A new reader arriving while the writer waits must not starve it.
        let lateReaderIn = Flag()
        let overtook = Flag()
        let r2 = Joinable {
            guard let g = try? locks.acquire([(A, .shared)]) else { return }
            if !writerIn.isSet {
                overtook.set()
            }
            lateReaderIn.set()
            g.release()
        }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(!lateReaderIn.isSet)

        // Unrelated resources stay available throughout.
        let t = ContinuousClock.now
        try locks.acquire([(B, .exclusive)]).release()
        #expect(ContinuousClock.now - t < .milliseconds(50))

        reader.release()
        #expect(w.join())
        #expect(r2.join())
        #expect(!overtook.isSet, "late reader overtook the writer")
        let holders = locks.holders(A)
        #expect(holders.readers == 0 && !holders.writer)
    }

    @Test func waitingForALockCanBeCancelled() throws {
        let locks = ResourceLocks()
        let held = try locks.acquire([(A, .exclusive)])
        let cancel = Flag()
        let gaveUp = Flag()
        let h = Joinable {
            do {
                let g = try locks.acquire([(A, .exclusive)]) { cancel.isSet }
                g.release()
            } catch {
                gaveUp.set()
            }
        }
        Thread.sleep(forTimeInterval: 0.08)
        cancel.set()
        #expect(h.join())
        #expect(gaveUp.isSet, "cancelled waiter must give up")
        // The cancelled waiter left no residue that would block readers later.
        held.release()
        try locks.acquire([(A, .shared)]).release()
    }

    @Test func multiResourceRequestsCannotDeadlock() {
        let locks = ResourceLocks()
        let joins = (0..<8).map { i in
            Joinable {
                let reqs: [(ResourceKey, LockMode)] = i % 2 == 0
                    ? [(A, .exclusive), (B, .exclusive)]
                    : [(B, .exclusive), (A, .exclusive)]
                for _ in 0..<20 {
                    (try? locks.acquire(reqs))?.release()
                }
            }
        }
        #expect(joins.allSatisfy { $0.join(timeout: .seconds(10)) }, "deadlock")
    }
}

// MARK: - Approvals

private let OWNER: UInt32 = 501
private let TTL: UInt64 = 60_000

private func plan(_ resource: String, _ state: String) -> ApprovalPlan {
    ApprovalPlan(
        planId: "p-1",
        resource: resource,
        contentDigest: "digest-\(resource)-\(state)",
        stateFingerprint: state,
        ownerUid: OWNER
    )
}

private func redeemError(
    _ store: ApprovalStore, _ t: ApprovalToken, _ p: ApprovalPlan, _ uid: UInt32, _ state: String, _ now: UInt64
) -> ApprovalError? {
    do {
        try store.redeem(t, plan: p, callerUid: uid, currentState: state, nowMs: now)
        return nil
    } catch {
        return error
    }
}

@Suite struct ApprovalTests {
    @Test func approvalRedeemsOnceForTheExactPlanAndState() throws {
        let store = ApprovalStore()
        let p = plan("fixture-a", "state-1")
        let token = try store.issue(p, approverUid: OWNER, nowMs: 1_000, ttlMs: TTL)
        #expect(redeemError(store, token, p, OWNER, "state-1", 2_000) == nil)
        #expect(redeemError(store, token, p, OWNER, "state-1", 2_001) == .alreadyUsed)
    }

    @Test func changedPlanChangedStateWrongOwnerAndExpiryAreRefused() throws {
        let store = ApprovalStore()
        let p = plan("fixture-a", "state-1")

        var t = try store.issue(p, approverUid: OWNER, nowMs: 0, ttlMs: TTL)
        var changed = p
        changed.contentDigest = "digest-changed"
        #expect(redeemError(store, t, changed, OWNER, "state-1", 1) == .planMismatch)
        // The failed attempt burned the token.
        #expect(redeemError(store, t, p, OWNER, "state-1", 2) == .alreadyUsed)

        t = try store.issue(p, approverUid: OWNER, nowMs: 0, ttlMs: TTL)
        #expect(redeemError(store, t, p, OWNER, "state-2", 1) == .stateChanged)

        t = try store.issue(p, approverUid: OWNER, nowMs: 0, ttlMs: TTL)
        #expect(redeemError(store, t, p, OWNER + 1, "state-1", 1) == .wrongOwner)

        t = try store.issue(p, approverUid: OWNER, nowMs: 0, ttlMs: TTL)
        #expect(redeemError(store, t, p, OWNER, "state-1", TTL) == .expired)

        #expect(throws: ApprovalError.wrongOwner) {
            try store.issue(p, approverUid: OWNER + 1, nowMs: 0, ttlMs: TTL)
        }
        #expect(redeemError(store, .fromClient("forged"), p, OWNER, "state-1", 1) == .unknownToken)
    }

    @Test func approvingANewPlanInvalidatesOlderApprovalsForThatResource() throws {
        let store = ApprovalStore()
        let old = plan("fixture-a", "state-1")
        let oldToken = try store.issue(old, approverUid: OWNER, nowMs: 0, ttlMs: TTL)
        let otherResource = try store.issue(plan("fixture-b", "s"), approverUid: OWNER, nowMs: 0, ttlMs: TTL)

        let new = plan("fixture-a", "state-2")
        let newToken = try store.issue(new, approverUid: OWNER, nowMs: 1, ttlMs: TTL)
        #expect(redeemError(store, oldToken, old, OWNER, "state-1", 2) == .unknownToken)
        #expect(redeemError(store, newToken, new, OWNER, "state-2", 2) == nil)
        #expect(redeemError(store, otherResource, plan("fixture-b", "s"), OWNER, "s", 2) == nil)

        let t = try store.issue(new, approverUid: OWNER, nowMs: 3, ttlMs: TTL)
        store.revokeResource("fixture-a")
        #expect(redeemError(store, t, new, OWNER, "state-2", 4) == .unknownToken)
    }

    @Test func tokensNeverAppearInDebugOutputAndAreUnpredictable() throws {
        let store = ApprovalStore()
        let t1 = try store.issue(plan("fixture-a", "s"), approverUid: OWNER, nowMs: 0, ttlMs: TTL)
        let t2 = try store.issue(plan("fixture-b", "s"), approverUid: OWNER, nowMs: 0, ttlMs: TTL)
        #expect(t1.expose().count == 64)
        #expect(t1.expose() != t2.expose())
        let dbg = "\(String(reflecting: t1)) \(t1)"
        #expect(!dbg.contains(t1.expose()), "\(dbg)")
        #expect(!"\(store)".contains(t1.expose()))
        #expect(!String(reflecting: store).contains(t1.expose()))
    }

    @Test func approvalDigestIsTheCorePlanDigest() {
        let p = plan("fixture-a", "s")
        #expect(p.digest == p.contentDigest)
        var q = p
        q.ownerUid += 1
        q.planId = "p-2"
        q.stateFingerprint = "other"
        #expect(q.digest == p.digest)
        q.contentDigest = "core-digest"
        #expect(q.digest != p.digest)
    }
}
