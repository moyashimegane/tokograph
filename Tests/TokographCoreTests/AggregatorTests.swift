import XCTest
@testable import TokographCore

final class AggregatorTests: XCTestCase {
    // Fixed zone with DST: America/New_York. Spring-forward 2026-03-08, fall-back 2026-11-01.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func rec(_ iso: String, total: Int64 = 10, id: String = UUID().uuidString) -> UsageRecord {
        UsageRecord(timestamp: LineParser.parseISO8601(iso)!, tokens: TokenCounts(input: total),
                    model: "m", project: "p", sessionId: nil, messageId: id, requestId: nil)
    }
    private let now = LineParser.parseISO8601("2026-07-18T12:00:00Z")!

    func testUTCtoLocalDayBoundary() {
        // 03:30Z on Jul 18 = 23:30 EDT on Jul 17 → belongs to Jul 17 local, hour 23
        let r = Aggregator.aggregate(records: [rec("2026-07-18T03:30:00Z")], now: now, calendar: cal)
        let key = r.cells.keys.first!
        XCTAssertEqual(cal.component(.day, from: key.day), 17)
        XCTAssertEqual(key.hour, 23)
    }
    func testWindowStartInclusionAndExclusion() {
        // now local = Jul 18 08:00 EDT → window start = startOfDay(Jul 5 local) = Jul 5 04:00Z (EDT=-4)
        let inside = rec("2026-07-05T04:00:00Z")   // exactly window start
        let outside = rec("2026-07-05T03:59:59Z")  // 1s before
        let r = Aggregator.aggregate(records: [inside, outside], now: now, calendar: cal)
        XCTAssertEqual(r.inWindowRecordCount, 1)
        XCTAssertEqual(r.totalRecordCount, 2)
        XCTAssertEqual(r.futureTimestamps, 0)
        XCTAssertEqual(r.totals.visibleWindow, WideUInt(10))
    }
    func testTotalsUseNowAnchoredTodayAndSevenDayBoundaries() {
        // now local = Jul 18 08:00 EDT; 7d begins at Jul 12 00:00 EDT (04:00Z).
        let records = [
            rec("2026-07-18T04:00:00Z", total: 1),
            rec("2026-07-18T03:59:59Z", total: 2),
            rec("2026-07-12T04:00:00Z", total: 4),
            rec("2026-07-12T03:59:59Z", total: 8),
            rec("2026-07-18T12:00:01Z", total: 16),
        ]
        let r = Aggregator.aggregate(records: records, now: now, calendar: cal)
        XCTAssertEqual(r.totals.today, WideUInt(1))
        XCTAssertEqual(r.totals.last7Days, WideUInt(7))
        XCTAssertEqual(r.totals.visibleWindow, WideUInt(15))
    }
    func testTotalsRemainWideAcrossCells() {
        let records = [
            rec("2026-07-18T10:00:00Z", total: Int64.max),
            rec("2026-07-18T11:00:00Z", total: Int64.max),
        ]
        let r = Aggregator.aggregate(records: records, now: now, calendar: cal)
        let expected = WideUInt(UInt64(Int64.max)) + WideUInt(UInt64(Int64.max))
        XCTAssertEqual(r.totals.today, expected)
        XCTAssertEqual(r.totals.last7Days, expected)
        XCTAssertEqual(r.totals.visibleWindow, expected)
        XCTAssertTrue(r.totals.visibleWindow.isAboveInt64Max)
    }
    func testFutureTimestampCountedAndDropped() {
        let r = Aggregator.aggregate(records: [rec("2026-07-18T12:00:01Z")], now: now, calendar: cal)
        XCTAssertEqual(r.futureTimestamps, 1); XCTAssertTrue(r.cells.isEmpty)
    }
    func testDSTFallBackMergesDoubledHour() {
        // 2026-11-01: 01:30 EDT (05:30Z) and 01:30 EST (06:30Z) — same wall-clock hour 1
        let nowNov = LineParser.parseISO8601("2026-11-02T00:00:00Z")!
        let r = Aggregator.aggregate(
            records: [rec("2026-11-01T05:30:00Z", total: 1), rec("2026-11-01T06:30:00Z", total: 2)],
            now: nowNov, calendar: cal)
        XCTAssertEqual(r.cells.count, 1)
        XCTAssertEqual(r.cells.values.first, WideUInt(3))
        XCTAssertEqual(r.cells.keys.first?.hour, 1)
    }
    func testThresholdsNearestRank() {
        // n=8, values 1...8 → q1=v⌈2⌉=2, q2=v⌈4⌉=4, q3=v⌈6⌉=6
        let t = Aggregator.thresholds(nonZero: (1...8).map { WideUInt(UInt64($0)) })!
        XCTAssertEqual([t.q1, t.q2, t.q3], [WideUInt(2), WideUInt(4), WideUInt(6)])
    }
    func testThresholdsSmallN() {
        let t1 = Aggregator.thresholds(nonZero: [WideUInt(7)])!    // n=1 → all q = v1
        XCTAssertEqual([t1.q1, t1.q2, t1.q3], [WideUInt(7), WideUInt(7), WideUInt(7)])
        let t3 = Aggregator.thresholds(nonZero: [3, 1, 2].map { WideUInt(UInt64($0)) })! // unsorted input
        XCTAssertEqual([t3.q1, t3.q2, t3.q3], [WideUInt(1), WideUInt(2), WideUInt(3)])   // ⌈3/4⌉=1,⌈6/4⌉=2,⌈9/4⌉=3
        XCTAssertNil(Aggregator.thresholds(nonZero: []))
    }
    func testBucketAssignment() {
        let t = (q1: WideUInt(2), q2: WideUInt(4), q3: WideUInt(6))
        XCTAssertEqual(Aggregator.bucket(WideUInt(0), thresholds: t), 0)
        XCTAssertEqual(Aggregator.bucket(WideUInt(2), thresholds: t), 1)
        XCTAssertEqual(Aggregator.bucket(WideUInt(3), thresholds: t), 2)
        XCTAssertEqual(Aggregator.bucket(WideUInt(4), thresholds: t), 2)
        XCTAssertEqual(Aggregator.bucket(WideUInt(6), thresholds: t), 3)
        XCTAssertEqual(Aggregator.bucket(WideUInt(7), thresholds: t), 4)
        XCTAssertEqual(Aggregator.bucket(WideUInt(5), thresholds: nil), 0) // no data ⇒ only zero bucket
    }
    func testHeavyTiesDeterministic() {
        let t = Aggregator.thresholds(nonZero: Array(repeating: WideUInt(5), count: 10))!
        XCTAssertEqual([t.q1, t.q2, t.q3], [WideUInt(5), WideUInt(5), WideUInt(5)])
        XCTAssertEqual(Aggregator.bucket(WideUInt(5), thresholds: t), 1) // v≤q1 → 1
    }
}
