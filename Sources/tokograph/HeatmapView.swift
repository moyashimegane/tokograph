import SwiftUI
import TokographCore

struct HeatmapPopover: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                StateMessage(text: "No usage in the last 14 days.")
            }
            footer
        }
        .padding(12)
        .frame(width: 480)
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
    let snapshot: DisplaySnapshot
    @State private var hovered: DayHour?
    private let cellW: CGFloat = 26, cellH: CGFloat = 11

    private var calendar: Calendar { .current }
    private var thresholds: (q1: WideUInt, q2: WideUInt, q3: WideUInt)? {
        guard let t = snapshot.thresholds3, t.count == 3 else { return nil }
        return (t[0], t[1], t[2])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                hourLabels
                VStack(spacing: 2) {
                    dayHeaders
                    grid
                }
            }
            hoverDetail
        }
    }

    private var dayHeaders: some View {
        HStack(spacing: 2) {
            ForEach(snapshot.windowDays, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: snapshot.now)
                VStack(spacing: 0) {
                    // Month line always renders (empty placeholder when not shown) so every
                    // column — and the hour-label spacer below — has the same fixed two-line
                    // height; otherwise the grid shifts ~1 row against the hour labels whenever
                    // the first column (which always shows its month) sets the tallest header.
                    Text(showsMonth(day) ? day.formatted(.dateTime.month(.abbreviated)) : " ")
                        .font(.system(size: 8))
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 9, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : .secondary)
                }
                .frame(width: cellW)
            }
        }
    }

    private func showsMonth(_ day: Date) -> Bool {
        day == snapshot.windowDays.first || calendar.component(.day, from: day) == 1
    }

    private var hourLabels: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Mirrors dayHeaders' two-line (month + day-number) header height exactly.
            VStack(spacing: 0) {
                Text(" ").font(.system(size: 8))
                Text(" ").font(.system(size: 9))
            }
            ForEach(0..<24, id: \.self) { h in
                Text(h % 3 == 0 ? "\(h)" : " ")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
                    .frame(height: cellH)
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

    /// Fixed-height detail strip: instant hover feedback.
    /// (AppKit `.help` tooltips do not fire inside MenuBarExtra's non-activating panel.)
    var hoverDetail: some View {
        Group {
            if let key = hovered {
                let value = snapshot.cells[key] ?? WideUInt(0)
                Text(tooltip(day: key.day, hour: key.hour, value: value))
                    .font(.caption).monospacedDigit()
            } else {
                Text("Hover a cell for details")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 14, alignment: .leading)
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
        .frame(width: 480)
}
#endif
