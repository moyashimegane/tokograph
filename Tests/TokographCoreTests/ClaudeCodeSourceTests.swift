import XCTest
@testable import TokographCore

final class ClaudeCodeSourceTests: XCTestCase {
    private var root: URL!
    private var projects: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projects = root.appendingPathComponent("projects")
        try fm.createDirectory(at: projects.appendingPathComponent("proj-a"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func write(_ name: String, _ lines: [String], project: String = "proj-a") throws {
        let dir = projects.appendingPathComponent(project)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent(name),
                                                atomically: true, encoding: .utf8)
    }
    private func usageLine(mid: String, tokens: Int) -> String {
        #"{"type":"assistant","timestamp":"2026-07-18T03:00:00Z","requestId":"r-\#(mid)","sessionId":"s","# +
        #""isSidechain":false,"message":{"id":"\#(mid)","model":"m","usage":{"input_tokens":\#(tokens)}}}"#
    }

    func testCollectsAndDedupsAcrossFiles() throws {
        try write("a.jsonl", [usageLine(mid: "m1", tokens: 10), usageLine(mid: "m2", tokens: 20)])
        try write("b.jsonl", [usageLine(mid: "m1", tokens: 10)], project: "proj-b") // duplicate across projects
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.records.count, 2)
        XCTAssertEqual(r.recognizedUsageLines, 3)
        XCTAssertEqual(r.enumeratedFileCount, 2); XCTAssertEqual(r.parsedFileCount, 2)
        XCTAssertFalse(r.capExceeded); XCTAssertFalse(r.enumerationFailed)
    }
    func testProjectNameFromDirectory() throws {
        try write("a.jsonl", [usageLine(mid: "m1", tokens: 1)])
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.records.first?.project, "proj-a")
    }
    func testCountersFromMixedContent() throws {
        try write("a.jsonl", [usageLine(mid: "m1", tokens: 1),
                              "{broken",
                              #"{"type":"user","message":{"usage":{"input_tokens":5}}}"#]) // anomalous
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.diagnostics.malformedLines, 1)
        XCTAssertEqual(r.diagnostics.anomalousLines, 1)
        XCTAssertEqual(r.records.count, 1)
    }
    func testNonJsonlAndSymlinksIgnored() throws {
        try write("a.jsonl", [usageLine(mid: "m1", tokens: 1)])
        try "x".write(to: projects.appendingPathComponent("proj-a/notes.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: projects.appendingPathComponent("proj-a/link.jsonl"),
                                  withDestinationURL: projects.appendingPathComponent("proj-a/a.jsonl"))
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.enumeratedFileCount, 1) // symlink and .txt excluded
        XCTAssertEqual(r.records.count, 1)
    }
    func testUnreadableFileCountedOthersParsed() throws {
        try write("a.jsonl", [usageLine(mid: "m1", tokens: 1)])
        try write("b.jsonl", [usageLine(mid: "m2", tokens: 1)])
        let locked = projects.appendingPathComponent("proj-a/b.jsonl")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock { try? self.fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.diagnostics.unreadableFiles, 1)
        XCTAssertEqual(r.records.count, 1)
    }
    func testProjectsDirWithZeroJsonlFilesIsEmptyNotCrash() throws {
        // projects/proj-a exists (created in setUp) but contains no .jsonl files
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.enumeratedFileCount, 0)
        XCTAssertEqual(r.records.count, 0)
        XCTAssertFalse(r.enumerationFailed)
    }
    func testRawRecordCountAboveCapSetsCapExceeded() throws {
        // Small injected cap (test-only override of the internal static var) so the test stays
        // fast: 10 files x 2 records = 20 raw records, well above cap=5, none of them colliding
        // (distinct messageId), so this exercises the pre-dedup running-total gate, not the
        // Deduplicator's own key cap.
        ClaudeCodeSource.recordCountCap = 5
        addTeardownBlock { ClaudeCodeSource.recordCountCap = 2_000_000 }
        for i in 0..<10 {
            try write("f\(i).jsonl", [usageLine(mid: "m\(i)-1", tokens: 1), usageLine(mid: "m\(i)-2", tokens: 1)])
        }
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertTrue(r.capExceeded)
    }
    func testEnumerationErrorHandlerCountsUnreadableAndContinues() throws {
        try write("a.jsonl", [usageLine(mid: "m1", tokens: 1)])
        let blockedDir = projects.appendingPathComponent("blocked")
        try fm.createDirectory(at: blockedDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedDir.path)
        addTeardownBlock { try? self.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDir.path) }
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.diagnostics.unreadableFiles, 1) // errorHandler invocation for the blocked dir
        XCTAssertEqual(r.enumeratedFileCount, 1) // a.jsonl still enumerated despite the error elsewhere
        XCTAssertFalse(r.enumerationFailed) // partial error, not a hard enumerator-nil failure
    }
    func testMissingProjectsDirIsEmptyNotError() throws {
        let bare = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bare) }
        let r = try ClaudeCodeSource().collect(root: bare)
        XCTAssertEqual(r.enumeratedFileCount, 0); XCTAssertFalse(r.enumerationFailed)
    }
    func testDeterministicScanOrderForTieBreak() throws {
        // Same mid, same totals, different output split; earlier path (a.jsonl) must win.
        let first = #"{"type":"assistant","timestamp":"2026-07-18T03:00:00Z","requestId":"r1","message":{"id":"m1","model":"m","usage":{"input_tokens":6,"output_tokens":4}}}"#
        let second = #"{"type":"assistant","timestamp":"2026-07-18T03:00:00Z","requestId":"r1","message":{"id":"m1","model":"m","usage":{"input_tokens":4,"output_tokens":6}}}"#
        try write("a.jsonl", [first]); try write("b.jsonl", [second])
        let r = try ClaudeCodeSource().collect(root: root)
        XCTAssertEqual(r.records.first?.tokens.output, 4)
    }
}
