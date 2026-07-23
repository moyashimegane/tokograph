import XCTest
@testable import TokographCore

final class RefreshEngineTests: XCTestCase {
    private func src(files: Int = 1, parsed: Int = 1, usage: Int = 1, usageLike: Int = 0,
                     cap: Bool = false, enumFail: Bool = false,
                     unreadable: Int = 0, records: [UsageRecord] = []) -> SourceResult {
        var s = SourceResult()
        s.enumeratedFileCount = files; s.parsedFileCount = parsed
        s.recognizedUsageLines = usage; s.diagnostics.unrecognizedUsageLike = usageLike
        s.capExceeded = cap; s.enumerationFailed = enumFail
        s.diagnostics.unreadableFiles = unreadable; s.records = records
        return s
    }
    private func agg(inWindow: Int, total: Int) -> AggregationResult {
        var a = AggregationResult()
        a.inWindowRecordCount = inWindow; a.totalRecordCount = total
        return a
    }
    private let okRoot = ConfigRootResolution.resolved(URL(fileURLWithPath: "/tmp/x"))

    // State priority order (first match wins)
    func testConfigErrorWinsOverEverything() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: .configError,
            source: src(enumFail: true), aggregation: agg(inWindow: 0, total: 0)), .configError)
    }
    func testEnumerationFailureIsError() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(enumFail: true), aggregation: agg(inWindow: 0, total: 0)), .error)
    }
    func testAllFilesUnreadableIsError() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(files: 3, parsed: 0, usage: 0, unreadable: 3),
            aggregation: agg(inWindow: 0, total: 0)), .error)
    }
    func testCapExceededIsError() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(cap: true), aggregation: agg(inWindow: 1, total: 1)), .error)
    }
    func testFormatChanged() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(parsed: 2, usage: 0, usageLike: 5),
            aggregation: agg(inWindow: 0, total: 0)), .formatChanged)
    }
    func testEmptyWhenNoFilesOrNoUsageAtAll() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(files: 0, parsed: 0, usage: 0), aggregation: agg(inWindow: 0, total: 0)), .empty)
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(usage: 0), aggregation: agg(inWindow: 0, total: 0)), .empty)
    }
    func testNoRecentDataWhenUsageExistsOutsideWindow() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(usage: 5), aggregation: agg(inWindow: 0, total: 5)), .noRecentData)
    }
    func testOk() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(usage: 5), aggregation: agg(inWindow: 5, total: 5)), .ok)
    }
    // formatChanged beats empty (priority): parsed>0, usage-like>0 → formatChanged even though usage==0
    func testFormatChangedBeatsEmpty() {
        XCTAssertEqual(RefreshEngine.deriveState(resolution: okRoot,
            source: src(files: 1, parsed: 1, usage: 0, usageLike: 1),
            aggregation: agg(inWindow: 0, total: 0)), .formatChanged)
    }
    // Full pipeline smoke via stub source
    struct StubSource: UsageSource {
        let result: SourceResult
        func collect(root: URL) throws -> SourceResult { result }
    }
    func testSaturationEventsCountedForCellsAboveInt64Max() {
        // Two records, each with a per-field token count ≤ Int64.max (individually valid), that
        // land in the same day/hour cell and sum above Int64.max.
        let ts = Date(timeIntervalSinceNow: -3600)
        let r1 = UsageRecord(timestamp: ts, tokens: TokenCounts(input: Int64.max - 10), model: "m",
                             project: "p", sessionId: nil, messageId: "m1", requestId: nil)
        let r2 = UsageRecord(timestamp: ts, tokens: TokenCounts(input: 100), model: "m",
                             project: "p", sessionId: nil, messageId: "m2", requestId: nil)
        let snap = RefreshEngine.runRefresh(
            defaultsValue: nil, env: [:], home: FileManager.default.temporaryDirectory,
            source: StubSource(result: src(usage: 2, records: [r1, r2])),
            now: Date(), calendar: .current)
        XCTAssertEqual(snap.diagnostics.saturationEvents, 1)
    }
    func testRunRefreshWiresCapExceededOntoSnapshot() {
        let snap = RefreshEngine.runRefresh(
            defaultsValue: nil, env: [:], home: FileManager.default.temporaryDirectory,
            source: StubSource(result: src(cap: true)),
            now: Date(), calendar: .current)
        XCTAssertEqual(snap.state, .error)
        XCTAssertTrue(snap.capExceeded)
    }
    func testRunRefreshProducesSnapshot() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = UsageRecord(timestamp: now,
                                 tokens: TokenCounts(input: 42), model: "m", project: "p",
                                 sessionId: nil, messageId: "m1", requestId: nil)
        let snap = RefreshEngine.runRefresh(
            defaultsValue: nil, env: [:], home: FileManager.default.temporaryDirectory,
            source: StubSource(result: src(usage: 1, records: [record])),
            now: now, calendar: .current)
        XCTAssertEqual(snap.state, .ok)
        XCTAssertEqual(snap.windowDays.count, 14)
        XCTAssertEqual(snap.cells.values.first, WideUInt(42))
        XCTAssertEqual(snap.dailyTotals.values.first, WideUInt(42))
        XCTAssertEqual(snap.perModel.values.first, ["m": WideUInt(42)])
        XCTAssertEqual(snap.totals.windowEndDay, WideUInt(42))
        XCTAssertEqual(snap.totals.last7Days, WideUInt(42))
        XCTAssertEqual(snap.totals.visibleWindow, WideUInt(42))
    }
    func testHistoricalWindowUsesRequestedEndDayAndActualNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = LineParser.parseISO8601("2026-07-18T12:00:00Z")!
        let end = LineParser.parseISO8601("2026-07-11T16:00:00Z")!
        let included = UsageRecord(
            timestamp: LineParser.parseISO8601("2026-07-12T03:59:59Z")!,
            tokens: TokenCounts(input: 2), model: "m", project: "p",
            sessionId: nil, messageId: "m1", requestId: nil)
        let newerPast = UsageRecord(
            timestamp: LineParser.parseISO8601("2026-07-12T04:00:00Z")!,
            tokens: TokenCounts(input: 4), model: "m", project: "p",
            sessionId: nil, messageId: "m2", requestId: nil)
        let actualFuture = UsageRecord(
            timestamp: LineParser.parseISO8601("2026-07-18T12:00:01Z")!,
            tokens: TokenCounts(input: 8), model: "m", project: "p",
            sessionId: nil, messageId: "m3", requestId: nil)

        let snap = RefreshEngine.runRefresh(
            defaultsValue: nil, env: [:], home: FileManager.default.temporaryDirectory,
            source: StubSource(result: src(usage: 3,
                                          records: [included, newerPast, actualFuture])),
            now: now, windowEnd: end, calendar: calendar)

        XCTAssertEqual(snap.state, .ok)
        XCTAssertEqual(snap.windowDays.count, 14)
        XCTAssertEqual(calendar.component(.day, from: snap.windowDays.first!), 28)
        XCTAssertEqual(calendar.component(.month, from: snap.windowDays.first!), 6)
        XCTAssertEqual(calendar.component(.day, from: snap.windowDays.last!), 11)
        XCTAssertEqual(snap.cells.values.first, WideUInt(2))
        XCTAssertEqual(snap.dailyTotals.values.first, WideUInt(2))
        XCTAssertEqual(snap.totals.windowEndDay, WideUInt(2))
        XCTAssertEqual(snap.diagnostics.futureTimestamps, 1)
    }
    func testFutureRequestedWindowIsClampedToActualToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = LineParser.parseISO8601("2026-07-18T12:00:00Z")!
        let futureEnd = LineParser.parseISO8601("2026-07-25T12:00:00Z")!
        let record = UsageRecord(timestamp: now, tokens: TokenCounts(input: 1), model: "m",
                                 project: "p", sessionId: nil, messageId: "m1", requestId: nil)

        let snap = RefreshEngine.runRefresh(
            defaultsValue: nil, env: [:], home: FileManager.default.temporaryDirectory,
            source: StubSource(result: src(usage: 1, records: [record])),
            now: now, windowEnd: futureEnd, calendar: calendar)

        XCTAssertTrue(calendar.isDate(snap.windowDays.last!, inSameDayAs: now))
        XCTAssertEqual(snap.totals.windowEndDay, WideUInt(1))
    }
}
