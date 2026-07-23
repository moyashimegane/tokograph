/// 128-bit unsigned integer for overflow-safe token sums; saturates only at presentation.
public struct WideUInt: Equatable, Comparable, Hashable, Sendable {
    public var high: UInt64
    public var low: UInt64

    public init(high: UInt64, low: UInt64) { self.high = high; self.low = low }
    public init(_ value: UInt64) { self.init(high: 0, low: value) }

    public static func + (lhs: WideUInt, rhs: WideUInt) -> WideUInt {
        let (low, carry) = lhs.low.addingReportingOverflow(rhs.low)
        // High-word overflow is unreachable with Int64-validated inputs; wrap is acceptable there.
        let high = lhs.high &+ rhs.high &+ (carry ? 1 : 0)
        return WideUInt(high: high, low: low)
    }

    public static func < (lhs: WideUInt, rhs: WideUInt) -> Bool {
        lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
    }

    public var isAboveInt64Max: Bool { high > 0 || low > UInt64(Int64.max) }
    /// Clamped value for presentation only. Never use for comparisons.
    public var saturatedInt64: Int64 { isAboveInt64Max ? Int64.max : Int64(low) }

    /// Returns `floor(self / maximum * scale)` without narrowing either value.
    public func scaled(to scale: UInt64, relativeTo maximum: WideUInt) -> UInt64 {
        guard scale > 0, maximum > WideUInt(0), self > WideUInt(0) else { return 0 }
        guard self < maximum else { return scale }

        var lower: UInt64 = 0
        var upper = scale
        while lower < upper {
            let distance = upper - lower
            let candidate = lower + distance / 2 + distance % 2
            if Self.compareProduct(self, scale, maximum, candidate) >= 0 {
                lower = candidate
            } else {
                upper = candidate - 1
            }
        }
        return lower
    }

    private static func compareProduct(_ lhs: WideUInt, _ lhsFactor: UInt64,
                                       _ rhs: WideUInt, _ rhsFactor: UInt64) -> Int {
        let left = productWords(lhs, lhsFactor)
        let right = productWords(rhs, rhsFactor)
        if left.high != right.high { return left.high < right.high ? -1 : 1 }
        if left.middle != right.middle { return left.middle < right.middle ? -1 : 1 }
        if left.low != right.low { return left.low < right.low ? -1 : 1 }
        return 0
    }

    /// Exact 128-by-64-bit multiplication represented as three 64-bit words.
    private static func productWords(_ value: WideUInt, _ factor: UInt64)
        -> (high: UInt64, middle: UInt64, low: UInt64) {
        let lowProduct = value.low.multipliedFullWidth(by: factor)
        let highProduct = value.high.multipliedFullWidth(by: factor)
        let (middle, carry) = lowProduct.high.addingReportingOverflow(highProduct.low)
        return (highProduct.high &+ (carry ? 1 : 0), middle, lowProduct.low)
    }
}
