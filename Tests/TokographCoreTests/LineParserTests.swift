import XCTest
@testable import TokographCore

final class LineParserTests: XCTestCase {
    private func classify(_ json: String) -> LineClass {
        var unknown = false
        return LineParser.classify(Data(json.utf8), project: "p", unknownTokenField: &unknown)
    }
    private func classifyUnknownFlag(_ json: String) -> Bool {
        var unknown = false
        _ = LineParser.classify(Data(json.utf8), project: "p", unknownTokenField: &unknown)
        return unknown
    }
    private func valid(_ usage: String, type: String = "assistant",
                       ts: String = "2026-07-18T03:00:00.000Z",
                       mid: String = "\"msg_1\"", rid: String = "\"req_1\"") -> String {
        """
        {"type":"\(type)","timestamp":"\(ts)","requestId":\(rid),"sessionId":"s1","isSidechain":false,\
        "message":{"id":\(mid),"model":"opus-4-8","usage":\(usage)}}
        """
    }

    func testValidUsageLine() {
        let c = classify(valid(#"{"input_tokens":2,"output_tokens":3,"cache_creation_input_tokens":5,"cache_read_input_tokens":7}"#))
        guard case .usage(let r) = c else { return XCTFail("\(c)") }
        XCTAssertEqual(r.tokens, TokenCounts(input: 2, output: 3, cacheCreation: 5, cacheRead: 7))
        XCTAssertEqual(r.messageId, "msg_1"); XCTAssertEqual(r.requestId, "req_1")
        XCTAssertEqual(r.model, "opus-4-8"); XCTAssertEqual(r.project, "p")
    }
    func testMissingFieldsCountAsZero() {
        let c = classify(valid(#"{"input_tokens":2}"#))
        guard case .usage(let r) = c else { return XCTFail("\(c)") }
        XCTAssertEqual(r.tokens, TokenCounts(input: 2))
    }
    func testTimestampWithoutFractionalSeconds() {
        guard case .usage = classify(valid(#"{"input_tokens":1}"#, ts: "2026-07-18T03:00:00Z")) else { return XCTFail() }
    }
    // Anomalous (class 2)
    func testUsageNotObjectIsAnomalous() {
        for u in ["null", "\"str\"", "[1]", "42"] {
            XCTAssertEqual(classify(valid(u)), .anomalous, u)
        }
    }
    func testNonAssistantWithUsageIsAnomalous() {
        XCTAssertEqual(classify(valid(#"{"input_tokens":1}"#, type: "user")), .anomalous)
    }
    func testBadTimestampIsAnomalous() {
        XCTAssertEqual(classify(valid(#"{"input_tokens":1}"#, ts: "not-a-date")), .anomalous)
    }
    func testMissingOrNonStringMessageIdIsAnomalous() {
        XCTAssertEqual(classify(valid(#"{"input_tokens":1}"#, mid: "null")), .anomalous)
        XCTAssertEqual(classify(valid(#"{"input_tokens":1}"#, mid: "42")), .anomalous)
    }
    func testBadNumericValuesAreAnomalous() {
        for u in [#"{"input_tokens":-1}"#, #"{"input_tokens":true}"#,
                  #"{"input_tokens":1.5}"#, #"{"input_tokens":1e3}"#,
                  #"{"input_tokens":9223372036854775808}"#] {
            XCTAssertEqual(classify(valid(u)), .anomalous, u)
        }
    }
    // Unrecognized usage-like (class 3)
    func testUsageObjectWithZeroKnownFieldsIsUnrecognized() {
        XCTAssertEqual(classify(valid(#"{"inputTokens":5}"#)), .unrecognizedUsageLike) // camelCase rename
        XCTAssertEqual(classify(valid(#"{"web_search_requests":1}"#)), .unrecognizedUsageLike)
    }
    func testTopLevelUsageShapeIsUnrecognized() {
        let json = #"{"type":"assistant","timestamp":"2026-07-18T03:00:00Z","usage":{"input_tokens":5}}"#
        XCTAssertEqual(classify(json), .unrecognizedUsageLike)
    }
    // Malformed / non-usage
    func testInvalidJSONIsMalformed() { XCTAssertEqual(classify("{not json"), .malformed) }
    func testNonUsageLines() {
        XCTAssertEqual(classify(#"{"type":"user","message":{"role":"user"}}"#), .nonUsage)
        XCTAssertEqual(classify("42"), .nonUsage) // valid JSON fragment, nothing usage-like
    }
    // Unknown extra token field flag
    func testUnknownExtraTokenFieldSetsFlagButStillCounts() {
        let json = valid(#"{"input_tokens":2,"mystery_tokens":9}"#)
        XCTAssertTrue(classifyUnknownFlag(json))
        guard case .usage(let r) = classify(json) else { return XCTFail() }
        XCTAssertEqual(r.tokens, TokenCounts(input: 2)) // unknown key excluded from totals
    }
}
