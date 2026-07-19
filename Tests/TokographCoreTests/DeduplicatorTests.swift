import XCTest
@testable import TokographCore

final class DeduplicatorTests: XCTestCase {
    private func rec(_ mid: String, total: Int64, out: Int64 = 0, ts: TimeInterval = 0,
                     model: String? = "m", rid: String? = "r1") -> UsageRecord {
        UsageRecord(timestamp: Date(timeIntervalSince1970: ts),
                    tokens: TokenCounts(input: total - out, output: out),
                    model: model, project: "p", sessionId: "s", messageId: mid, requestId: rid)
    }

    func testMaxTotalWins() {
        var d = Deduplicator()
        XCTAssertTrue(d.insert(rec("a", total: 100, ts: 1)))
        XCTAssertTrue(d.insert(rec("a", total: 250, ts: 2))) // streaming growth
        XCTAssertEqual(d.records.count, 1)
        XCTAssertEqual(d.records[0].tokens.wideTotal, WideUInt(250))
        XCTAssertEqual(d.collisions, 0)
    }
    func testEqualTotalTieBreakEarliestTimestamp() {
        var d = Deduplicator()
        _ = d.insert(rec("a", total: 100, ts: 5))
        _ = d.insert(rec("a", total: 100, ts: 2))
        XCTAssertEqual(d.records[0].timestamp, Date(timeIntervalSince1970: 2))
    }
    func testFullTieKeepsFirstSeen() {
        var d = Deduplicator()
        _ = d.insert(rec("a", total: 100, out: 10, ts: 5))
        _ = d.insert(rec("a", total: 100, out: 20, ts: 5)) // same total & ts, different split
        XCTAssertEqual(d.records[0].tokens.output, 10)
    }
    func testModelMismatchIsCollision() {
        var d = Deduplicator()
        _ = d.insert(rec("a", total: 100, model: "m1"))
        _ = d.insert(rec("a", total: 200, model: "m2"))
        XCTAssertEqual(d.collisions, 1)
        XCTAssertEqual(d.records[0].tokens.wideTotal, WideUInt(200)) // max still counted
    }
    func testDifferingNonNilRequestIdsIsCollision() {
        var d = Deduplicator()
        _ = d.insert(rec("a", total: 100, rid: "r1"))
        _ = d.insert(rec("a", total: 200, rid: "r2"))
        XCTAssertEqual(d.collisions, 1)
    }
    func testMissingRequestIdIsNotCollision() {
        var d = Deduplicator()
        _ = d.insert(rec("a", total: 100, rid: nil))
        _ = d.insert(rec("a", total: 200, rid: "r1"))
        XCTAssertEqual(d.collisions, 0)
    }
    func testShrinkingFieldIsCollision() {
        var d = Deduplicator()
        _ = d.insert(rec("a", total: 100, out: 50))
        _ = d.insert(rec("a", total: 120, out: 30)) // total grew but output shrank
        XCTAssertEqual(d.collisions, 1)
    }
    func testCapExceededReturnsFalse() {
        var d = Deduplicator(cap: 2)
        XCTAssertTrue(d.insert(rec("a", total: 1)))
        XCTAssertTrue(d.insert(rec("b", total: 1)))
        XCTAssertFalse(d.insert(rec("c", total: 1)))
        XCTAssertTrue(d.insert(rec("a", total: 2))) // existing key still updatable
    }
}
