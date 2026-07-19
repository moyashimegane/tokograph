public enum TokenCountFormatter {
    public static func abbreviated(_ value: WideUInt) -> String {
        let saturated = UInt64(value.saturatedInt64)
        guard saturated >= 1_000 else { return String(saturated) }

        let units: [(divisor: UInt64, suffix: String)] = [
            (1_000, "K"),
            (1_000_000, "M"),
            (1_000_000_000, "B"),
        ]
        var unitIndex = saturated >= units[2].divisor ? 2
            : saturated >= units[1].divisor ? 1 : 0

        while true {
            let unit = units[unitIndex]
            let roundedTenths = saturated / unit.divisor * 10
                + (saturated % unit.divisor * 10 + unit.divisor / 2) / unit.divisor
            if roundedTenths >= 10_000 && unitIndex < units.count - 1 {
                unitIndex += 1
                continue
            }
            let whole = roundedTenths / 10
            let tenths = roundedTenths % 10
            return tenths == 0
                ? "\(whole)\(unit.suffix)"
                : "\(whole).\(tenths)\(unit.suffix)"
        }
    }
}
