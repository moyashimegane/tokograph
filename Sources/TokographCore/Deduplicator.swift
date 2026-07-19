import Foundation

public struct Deduplicator {
    private var byKey: [String: UsageRecord] = [:]
    public private(set) var collisions = 0
    public let cap: Int
    public init(cap: Int = 2_000_000) { self.cap = cap }

    public var records: [UsageRecord] { Array(byKey.values) }

    /// Returns false iff a NEW key would exceed the cap (caller aborts refresh → .error).
    public mutating func insert(_ r: UsageRecord) -> Bool {
        guard let existing = byKey[r.messageId] else {
            guard byKey.count < cap else { return false }
            byKey[r.messageId] = r
            return true
        }
        if isConflict(existing, r) { collisions += 1 }
        byKey[r.messageId] = better(existing, r)
        return true
    }

    private func isConflict(_ a: UsageRecord, _ b: UsageRecord) -> Bool {
        if let ma = a.model, let mb = b.model, ma != mb { return true }
        if let ra = a.requestId, let rb = b.requestId, ra != rb { return true }
        // Non-monotonic: any field of the lower-total occurrence exceeds the higher-total's.
        let (lo, hi) = a.tokens.wideTotal <= b.tokens.wideTotal ? (a, b) : (b, a)
        return lo.tokens.input > hi.tokens.input || lo.tokens.output > hi.tokens.output
            || lo.tokens.cacheCreation > hi.tokens.cacheCreation
            || lo.tokens.cacheRead > hi.tokens.cacheRead
    }

    /// Max wideTotal; tie → earliest timestamp; tie → keep existing (first-seen, scan order).
    private func better(_ existing: UsageRecord, _ new: UsageRecord) -> UsageRecord {
        if new.tokens.wideTotal != existing.tokens.wideTotal {
            return new.tokens.wideTotal > existing.tokens.wideTotal ? new : existing
        }
        return new.timestamp < existing.timestamp ? new : existing
    }
}
