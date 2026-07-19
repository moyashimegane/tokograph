import XCTest
@testable import TokographCore

final class TokenCountFormatterTests: XCTestCase {
    func testValuesBelowOneThousandAreNotAbbreviated() {
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(0)), "0")
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(999)), "999")
    }

    func testAbbreviatesThousandsMillionsAndBillions() {
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(1_200)), "1.2K")
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(42_300_000)), "42.3M")
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(1_100_000_000)), "1.1B")
    }

    func testOmitsTrailingZeroAndRoundsToOneDecimalPlace() {
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(1_000)), "1K")
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(1_250)), "1.3K")
        XCTAssertEqual(TokenCountFormatter.abbreviated(WideUInt(999_950)), "1M")
    }

    func testSaturatesWideValuesOnlyForPresentation() {
        let aboveInt64 = WideUInt(UInt64(Int64.max)) + WideUInt(1)
        XCTAssertEqual(
            TokenCountFormatter.abbreviated(aboveInt64),
            TokenCountFormatter.abbreviated(WideUInt(UInt64(Int64.max))))
    }
}
