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
}
