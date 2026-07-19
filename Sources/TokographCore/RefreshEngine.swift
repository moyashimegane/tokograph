import Foundation

public struct DisplaySnapshot: Sendable, Equatable {
    public var state: DataState
    public var cells: [DayHour: WideUInt]
    public var thresholds3: [WideUInt]?
    public var diagnostics: ParseDiagnostics
    public var windowDays: [Date]
    public var rootPath: String
    public var now: Date
    public var capExceeded: Bool = false
    public static let initial = DisplaySnapshot(state: .empty, cells: [:], thresholds3: nil,
                                                diagnostics: ParseDiagnostics(), windowDays: [],
                                                rootPath: "", now: .distantPast, capExceeded: false)
}

public enum RefreshEngine {
    public static func deriveState(resolution: ConfigRootResolution, source: SourceResult,
                                   aggregation: AggregationResult) -> DataState {
        // Spec §States & Diagnostics: first match wins.
        if case .configError = resolution { return .configError }
        if source.enumerationFailed || source.capExceeded
            || (source.enumeratedFileCount > 0 && source.parsedFileCount == 0) { return .error }
        if source.parsedFileCount > 0 && source.recognizedUsageLines == 0
            && source.diagnostics.unrecognizedUsageLike > 0 { return .formatChanged }
        if source.recognizedUsageLines == 0 { return .empty }
        if aggregation.inWindowRecordCount == 0 { return .noRecentData }
        return .ok
    }

    public static func runRefresh(defaultsValue: String?, env: [String: String], home: URL,
                                  source: UsageSource, now: Date,
                                  calendar: Calendar) -> DisplaySnapshot {
        let resolution = ConfigRoot.resolve(defaultsValue: defaultsValue, env: env, home: home)
        guard case .resolved(let root) = resolution else {
            return DisplaySnapshot(state: .configError, cells: [:], thresholds3: nil,
                                   diagnostics: ParseDiagnostics(), windowDays: [],
                                   rootPath: "", now: now)
        }
        let sourceResult: SourceResult
        do { sourceResult = try source.collect(root: root) }
        catch {
            var d = ParseDiagnostics(); d.unreadableFiles = 1
            return DisplaySnapshot(state: .error, cells: [:], thresholds3: nil, diagnostics: d,
                                   windowDays: [], rootPath: root.path, now: now)
        }
        let aggregation = Aggregator.aggregate(records: sourceResult.records, now: now, calendar: calendar)
        var diagnostics = sourceResult.diagnostics
        diagnostics.futureTimestamps = aggregation.futureTimestamps
        diagnostics.saturationEvents = aggregation.cells.values.filter { $0.isAboveInt64Max }.count

        let todayStart = calendar.startOfDay(for: now)
        let windowDays: [Date] = (0..<14).compactMap {
            calendar.date(byAdding: .day, value: -(13 - $0), to: todayStart)
        }
        let t = Aggregator.thresholds(nonZero: aggregation.cells.values.filter { $0 > WideUInt(0) })
        return DisplaySnapshot(
            state: deriveState(resolution: resolution, source: sourceResult, aggregation: aggregation),
            cells: aggregation.cells,
            thresholds3: t.map { [$0.q1, $0.q2, $0.q3] },
            diagnostics: diagnostics, windowDays: windowDays,
            rootPath: root.path, now: now, capExceeded: sourceResult.capExceeded)
    }
}
