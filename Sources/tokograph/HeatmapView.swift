import SwiftUI
import TokographCore

struct HeatmapPopover: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsFallbackPeriodNavigation {
                fallbackPeriodNavigation
            }
            switch store.snapshot.state {
            case .ok:
                HeatmapGrid(snapshot: store.snapshot)
            case .configError:
                StateMessage(text: "Config error: the configured log folder override is invalid or unreadable.")
            case .error:
                StateMessage(text: store.snapshot.capExceeded
                    ? "Dataset too large to analyze."
                    : "Could not read usage logs.")
            case .formatChanged:
                StateMessage(text: "Log format may have changed — check for a Tokograph update.")
            case .empty:
                StateMessage(text: "No usage data found. Tokograph reads Claude Code's local logs.")
            case .noRecentData:
                HeatmapGrid(snapshot: store.snapshot)
            }
            footer
        }
        .padding(12)
        .frame(width: 520)
    }

    private var showsFallbackPeriodNavigation: Bool {
        guard !store.isCurrentWindow, store.snapshot.windowDays.count == 14 else { return false }
        return store.snapshot.state != .ok && store.snapshot.state != .noRecentData
    }

    private var fallbackPeriodNavigation: some View {
        HStack(spacing: 6) {
            Button(action: store.showPreviousWeek) {
                Image(systemName: "chevron.left")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading)
            .help("Show previous week")
            .accessibilityLabel("Show previous week")

            Button(action: store.showNextWeek) {
                Image(systemName: "chevron.right")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading || store.isCurrentWindow)
            .help("Show next week")
            .accessibilityLabel("Show next week")

            Text(periodLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if !store.isCurrentWindow {
                Button("Today", action: store.showToday)
                    .font(.caption)
                    .disabled(store.isLoading)
            }
        }
    }

    private var periodLabel: String {
        guard let start = store.snapshot.windowDays.first,
              let end = store.snapshot.windowDays.last else { return "selected period" }
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.year().month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    private var footer: some View {
        HStack {
            if store.isLoading { ProgressView().controlSize(.small) }
            if store.lastRefreshFailed {
                Text("Last refresh failed")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !store.snapshot.diagnostics.isEmpty {
                Text(diagnosticsSummary(store.snapshot.diagnostics))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.font(.caption)
        }
    }

    private func diagnosticsSummary(_ d: ParseDiagnostics) -> String {
        var parts: [String] = []
        if d.unreadableFiles > 0 { parts.append("\(d.unreadableFiles) files") }
        let lines = d.malformedLines + d.anomalousLines
        if lines > 0 { parts.append("\(lines) lines skipped") }
        if d.unrecognizedUsageLike > 0 || d.unknownTokenFieldSeen { parts.append("unrecognized entries") }
        if d.dedupCollisions > 0 { parts.append("\(d.dedupCollisions) collisions") }
        if d.saturationEvents > 0 { parts.append("saturated values") }
        if d.futureTimestamps > 0 { parts.append("\(d.futureTimestamps) future-dated") }
        return parts.joined(separator: ", ")
    }
}

struct StateMessage: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
}

struct HeatmapGrid: View {
    private enum PeriodDirection: Hashable { case previous, next }

    @EnvironmentObject var store: UsageStore
    let snapshot: DisplaySnapshot
    @State private var hovered: DayHour?
    @State private var hoveredPeriodButton: PeriodDirection?
    private let cellW: CGFloat = 30, cellH: CGFloat = 15
    private let monthFontSize: CGFloat = 11
    private let weekdayFontSize: CGFloat = 11
    private let dayFontSize: CGFloat = 12
    private let hourFontSize: CGFloat = 11

    private var calendar: Calendar { .current }
    private var thresholds: (q1: WideUInt, q2: WideUInt, q3: WideUInt)? {
        guard let t = snapshot.thresholds3, t.count == 3 else { return nil }
        return (t[0], t[1], t[2])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                dayNavigationHeader
                HStack(alignment: .top, spacing: 4) {
                    hourLabels
                    grid
                }
            }
            hoverDetail
            totalsFooter
        }
    }

    private var dayNavigationHeader: some View {
        HStack(spacing: 4) {
            periodButton(direction: .previous, systemImage: "chevron.left",
                         label: "Show previous week",
                         disabled: store.isLoading, action: store.showPreviousWeek)
            dayHeaders
            periodButton(direction: .next, systemImage: "chevron.right", label: "Show next week",
                         disabled: store.isLoading || store.isCurrentWindow,
                         action: store.showNextWeek)
        }
    }

    private func periodButton(direction: PeriodDirection, systemImage: String, label: String, disabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hoveredPeriodButton == direction && !disabled
                              ? Color.accentColor.opacity(0.14) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .onHover { inside in
            if inside && !disabled {
                hoveredPeriodButton = direction
            } else if hoveredPeriodButton == direction {
                hoveredPeriodButton = nil
            }
        }
        .onChange(of: disabled) { isDisabled in
            guard isDisabled, hoveredPeriodButton == direction else { return }
            hoveredPeriodButton = nil
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var totalsFooter: some View {
        HStack {
            Text("\(windowEndLabel) \(TokenCountFormatter.abbreviated(snapshot.totals.windowEndDay)) · "
                + "7d \(TokenCountFormatter.abbreviated(snapshot.totals.last7Days)) · "
                + "14d \(TokenCountFormatter.abbreviated(snapshot.totals.visibleWindow))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            if !store.isCurrentWindow {
                Button("Today", action: store.showToday)
                    .font(.caption)
                    .disabled(store.isLoading)
            }
        }
    }

    private var windowEndLabel: String {
        guard let end = snapshot.windowDays.last else { return "End day" }
        if calendar.isDate(end, inSameDayAs: snapshot.now) { return "Today" }
        return end.formatted(.dateTime.month(.abbreviated).day())
    }

    private var dayHeaders: some View {
        HStack(spacing: 2) {
            ForEach(snapshot.windowDays, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: snapshot.now)
                let weekday = calendar.component(.weekday, from: day)
                VStack(spacing: 0) {
                    // Month line always renders (empty placeholder when not shown) so every
                    // column — and the hour-label spacer below — has the same fixed three-line
                    // height; otherwise the grid shifts ~1 row against the hour labels whenever
                    // the first column (which always shows its month) sets the tallest header.
                    Text(showsMonth(day) ? day.formatted(.dateTime.month(.abbreviated)) : " ")
                        .font(.system(size: monthFontSize))
                        .foregroundStyle(.secondary)
                    Text(weekdaySymbol(weekday))
                        .font(.system(size: weekdayFontSize,
                                      weight: isToday ? .bold : .regular))
                        .foregroundStyle(dayHeaderColor(weekday: weekday, isToday: isToday))
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: dayFontSize,
                                      weight: isToday ? .bold : .medium))
                        .foregroundStyle(dayHeaderColor(weekday: weekday, isToday: isToday))
                        .monospacedDigit()
                }
                .frame(width: cellW)
            }
        }
    }

    private func weekdaySymbol(_ weekday: Int) -> String {
        calendar.veryShortStandaloneWeekdaySymbols[weekday - 1]
    }

    private func dayHeaderColor(weekday: Int, isToday: Bool) -> Color {
        if isToday { return .accentColor }
        if weekday == 1 { return .red }
        if weekday == 7 { return .blue }
        return .secondary
    }

    private func showsMonth(_ day: Date) -> Bool {
        day == snapshot.windowDays.first || calendar.component(.day, from: day) == 1
    }

    private var hourLabels: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(0..<24, id: \.self) { h in
                Text(h % 3 == 0 ? "\(h)" : " ")
                    .font(.system(size: hourFontSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 20, height: cellH, alignment: .trailing)
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(spacing: 2) {
                    ForEach(snapshot.windowDays, id: \.self) { day in
                        cell(day: day, hour: hour)
                    }
                }
            }
        }
    }

    private func cell(day: Date, hour: Int) -> some View {
        let key = DayHour(day: day, hour: hour)
        let value = snapshot.cells[key] ?? WideUInt(0)
        let bucket = Aggregator.bucket(value, thresholds: thresholds)
        return RoundedRectangle(cornerRadius: 2)
            .fill(color(bucket: bucket))
            .frame(width: cellW, height: cellH)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor, lineWidth: hovered == key ? 1 : 0)
            )
            .onHover { inside in
                if inside { hovered = key } else if hovered == key { hovered = nil }
            }
            .accessibilityLabel(tooltip(day: day, hour: hour, value: value))
    }

    /// Fixed-height detail area: instant hover feedback without resizing the popover.
    /// (AppKit `.help` tooltips do not fire inside MenuBarExtra's non-activating panel.)
    var hoverDetail: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let key = hovered {
                let value = snapshot.cells[key] ?? WideUInt(0)
                Text(tooltip(day: key.day, hour: key.hour, value: value))
                    .font(.caption).monospacedDigit()
                if let breakdown = modelBreakdown(for: key) {
                    Text(breakdown)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(4)
                        .truncationMode(.tail)
                } else {
                    Text("No model usage")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if snapshot.state == .noRecentData {
                Text("No usage in \(periodLabel). Older logs may have been removed by Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover a cell for details")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 72, alignment: .topLeading)
    }

    private var periodLabel: String {
        guard let start = snapshot.windowDays.first,
              let end = snapshot.windowDays.last else { return "selected period" }
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.year().month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    private func modelBreakdown(for key: DayHour) -> String? {
        guard let models = snapshot.perModel[key], !models.isEmpty else { return nil }
        return models.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map {
            "\($0.key) \(TokenCountFormatter.abbreviated($0.value))"
        }.joined(separator: "\n")
    }

    private func tooltip(day: Date, hour: Int, value: WideUInt) -> String {
        let d = day.formatted(.dateTime.month(.abbreviated).day())
        let n = value.saturatedInt64.formatted(.number)
        let prefix = value.isAboveInt64Max ? "at least " : ""
        return "\(d), \(hour):00, \(prefix)\(n) tokens"
    }

    private func color(bucket: Int) -> Color {
        // Single-hue sequential (teal), light/dark aware via opacity over a base.
        switch bucket {
        case 0: return Color.primary.opacity(0.06)
        case 1: return Color.teal.opacity(0.25)
        case 2: return Color.teal.opacity(0.45)
        case 3: return Color.teal.opacity(0.70)
        default: return Color.teal.opacity(0.95)
        }
    }
}

// DEBUG-only: on older toolchains (CI's macos-14 Xcode) a multi-statement
// #Preview body gets no implicit return, making the macro expansion ambiguous
// and failing release builds.
#if DEBUG
#Preview {
    let snap: DisplaySnapshot = {
        var s = DisplaySnapshot.initial
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        s.state = .ok
        s.cells = [DayHour(day: today, hour: 9): WideUInt(23_000_000),
                   DayHour(day: today, hour: 11): WideUInt(79_000_000)]
        s.perModel = [
            DayHour(day: today, hour: 9): [
                "claude-sonnet-5": WideUInt(18_000_000),
                "claude-haiku-4-5": WideUInt(5_000_000),
            ],
            DayHour(day: today, hour: 11): ["claude-opus-4-1": WideUInt(79_000_000)],
        ]
        s.totals.windowEndDay = WideUInt(102_000_000)
        s.totals.last7Days = WideUInt(408_000_000)
        s.totals.visibleWindow = WideUInt(702_000_000)
        s.thresholds3 = [WideUInt(23_000_000), WideUInt(40_000_000), WideUInt(60_000_000)]
        s.diagnostics = ParseDiagnostics()
        s.windowDays = (0..<14).compactMap {
            cal.date(byAdding: .day, value: -(13 - $0), to: today)
        }
        s.rootPath = "/tmp"
        s.now = .now
        return s
    }()
    return HeatmapPopover().environmentObject(UsageStore(snapshot: snap))
        .frame(width: 520)
}
#endif
