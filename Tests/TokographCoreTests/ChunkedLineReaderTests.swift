import XCTest
@testable import TokographCore

final class ChunkedLineReaderTests: XCTestCase {
    private func tmpFile(_ content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        try content.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func lines(of url: URL, cap: Int = 10_000, chunk: Int = 8) throws -> (lines: [String], dropped: Int) {
        var out: [String] = []
        let dropped = try ChunkedLineReader.forEachLine(url: url, capBytes: cap, chunkBytes: chunk) {
            out.append(String(decoding: $0, as: UTF8.self))
        }
        return (out, dropped)
    }

    func testSplitsLinesAcrossChunkBoundaries() throws {
        let url = try tmpFile(Data("abcdefghij\nklm\nnop\n".utf8)) // first line > chunk size 8
        let r = try lines(of: url)
        XCTAssertEqual(r.lines, ["abcdefghij", "klm", "nop"]); XCTAssertEqual(r.dropped, 0)
    }
    func testFinalUnterminatedLineIsDelivered() throws {
        let r = try lines(of: try tmpFile(Data("a\nlast-no-newline".utf8)))
        XCTAssertEqual(r.lines, ["a", "last-no-newline"])
    }
    func testOversizedLineDroppedAndSkippedToNewline() throws {
        let url = try tmpFile(Data(("x" + String(repeating: "y", count: 30) + "\nok\n").utf8))
        let r = try lines(of: url, cap: 10)
        XCTAssertEqual(r.lines, ["ok"]); XCTAssertEqual(r.dropped, 1)
    }
    func testOversizedNoNewlineFileDoesNotBufferUnbounded() throws {
        let r = try lines(of: try tmpFile(Data(String(repeating: "z", count: 100).utf8)), cap: 10)
        XCTAssertEqual(r.lines, []); XCTAssertEqual(r.dropped, 1)
    }
    func testOpenFailureThrows() {
        XCTAssertThrowsError(try ChunkedLineReader.forEachLine(
            url: URL(fileURLWithPath: "/nonexistent/x.jsonl"), capBytes: 10, chunkBytes: 8) { _ in })
    }
}
