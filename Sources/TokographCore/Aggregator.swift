import Foundation

public struct DayHour: Hashable, Sendable {
    public var day: Date   // startOfDay in the aggregation calendar
    public var hour: Int
    public init(day: Date, hour: Int) { self.day = day; self.hour = hour }
}

public struct UsageTotals: Sendable, Equatable {
    public var today = WideUInt(0)
    public var last7Days = WideUInt(0)
    public var visibleWindow = WideUInt(0)
    public init() {}
}

public struct AggregationResult: Sendable, Equatable {
    public var cells: [DayHour: WideUInt] = [:]
    public var perModel: [DayHour: [String: WideUInt]] = [:]
    public var totals = UsageTotals()
    public var futureTimestamps = 0
    public var inWindowRecordCount = 0
    public var totalRecordCount = 0
    public init() {}
}

public enum Aggregator {
    public static func aggregate(records: [UsageRecord], now: Date,
                                 calendar: Calendar, windowDays: Int = 14) -> AggregationResult {
        var result = AggregationResult()
        result.totalRecordCount = records.count
        let todayStart = calendar.startOfDay(for: now)
        guard let last7DaysStart = calendar.date(byAdding: .day, value: -6, to: todayStart),
              let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: todayStart) else {
            return result
        }
        for r in records {
            if r.timestamp > now { result.futureTimestamps += 1; continue }
            let total = r.tokens.wideTotal
            if r.timestamp >= last7DaysStart {
                result.totals.last7Days = result.totals.last7Days + total
                if r.timestamp >= todayStart {
                    result.totals.today = result.totals.today + total
                }
            }
            guard r.timestamp >= windowStart else { continue }
            let key = DayHour(day: calendar.startOfDay(for: r.timestamp),
                              hour: calendar.component(.hour, from: r.timestamp))
            result.cells[key, default: WideUInt(0)] = result.cells[key, default: WideUInt(0)] + total
            let model = r.model ?? "unknown"
            result.perModel[key, default: [:]][model, default: WideUInt(0)] =
                result.perModel[key, default: [:]][model, default: WideUInt(0)] + total
            result.totals.visibleWindow = result.totals.visibleWindow + total
            result.inWindowRecordCount += 1
        }
        return result
    }

    public static func thresholds(nonZero: [WideUInt]) -> (q1: WideUInt, q2: WideUInt, q3: WideUInt)? {
        guard !nonZero.isEmpty else { return nil }
        let v = nonZero.sorted()
        let n = v.count
        func q(_ k: Int) -> WideUInt { v[Int((Double(k) * Double(n) / 4.0).rounded(.up)) - 1] }
        return (q(1), q(2), q(3))
    }

    public static func bucket(_ v: WideUInt,
                              thresholds t: (q1: WideUInt, q2: WideUInt, q3: WideUInt)?) -> Int {
        guard v > WideUInt(0), let t else { return 0 }
        if v <= t.q1 { return 1 }
        if v <= t.q2 { return 2 }
        if v <= t.q3 { return 3 }
        return 4
    }
}
