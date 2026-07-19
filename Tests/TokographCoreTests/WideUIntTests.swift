import XCTest
@testable import TokographCore

final class WideUIntTests: XCTestCase {
    func testAdditionAndComparison() {
        let a = WideUInt(UInt64(Int64.max))
        let b = a + WideUInt(1)
        XCTAssertTrue(b > a)                       // no wraparound at Int64 boundary
        XCTAssertTrue(b.isAboveInt64Max)
        XCTAssertFalse(a.isAboveInt64Max)
        XCTAssertEqual(a.saturatedInt64, Int64.max)
        XCTAssertEqual(b.saturatedInt64, Int64.max) // saturates only at presentation
        XCTAssertEqual(WideUInt(2) + WideUInt(3), WideUInt(5))
    }
    func testDistinctTotalsNeverCompareEqualViaClamping() {
        let x = WideUInt(UInt64(Int64.max)) + WideUInt(10)
        let y = WideUInt(UInt64(Int64.max)) + WideUInt(20)
        XCTAssertNotEqual(x, y)                    // comparisons use the wide representation, not clamped values
        XCTAssertTrue(y > x)
    }
    func testCarryAcrossLowWord() {
        let x = WideUInt(UInt64.max) + WideUInt(1)
        XCTAssertEqual(x, WideUInt(high: 1, low: 0))
        XCTAssertTrue(x > WideUInt(UInt64.max))
    }
}
