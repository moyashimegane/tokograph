import SwiftUI
import AppKit
import TokographCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = DisplaySnapshot.initial
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshFailed = false
    @Published private(set) var selectedWindowEnd: Date?
    private var running = false
    private var dirty = false

    init(snapshot: DisplaySnapshot = .initial, selectedWindowEnd: Date? = nil) {
        self.snapshot = snapshot
        self.selectedWindowEnd = selectedWindowEnd
    }

    var isCurrentWindow: Bool { selectedWindowEnd == nil }

    func showPreviousWeek() {
        guard !isLoading else { return }
        let calendar = Calendar.current
        let currentEnd = selectedWindowEnd ?? calendar.startOfDay(for: Date())
        guard let previousEnd = calendar.date(byAdding: .day, value: -7, to: currentEnd) else { return }
        selectedWindowEnd = previousEnd
        refresh()
    }

    func showNextWeek() {
        guard !isLoading, let currentEnd = selectedWindowEnd else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let nextEnd = calendar.date(byAdding: .day, value: 7, to: currentEnd) else { return }
        selectedWindowEnd = nextEnd >= today ? nil : nextEnd
        refresh()
    }

    func showToday() {
        guard !isLoading, selectedWindowEnd != nil else { return }
        selectedWindowEnd = nil
        refresh()
    }

    func refresh() {
        if running { dirty = true; return } // coalesce
        running = true; isLoading = true
        let defaultsValue = UserDefaults.standard.string(forKey: "configRoot")
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()
        let calendar = Calendar.current
        let requestedWindowEnd = selectedWindowEnd
        // Cross-root rule: resolve synchronously and clear held data *before* detaching if the
        // resolved root differs from what's currently shown — the old root's data must never
        // remain visible while a different root's refresh is in flight.
        let resolution = ConfigRoot.resolve(defaultsValue: defaultsValue, env: env, home: home)
        let resolvedRootPath: String
        switch resolution {
        case .resolved(let root): resolvedRootPath = root.path
        case .configError: resolvedRootPath = ""
        }
        let previousRoot = snapshot.rootPath
        if !previousRoot.isEmpty && previousRoot != resolvedRootPath {
            snapshot = DisplaySnapshot.initial
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let snap = RefreshEngine.runRefresh(defaultsValue: defaultsValue, env: env, home: home,
                                                source: ClaudeCodeSource(), now: now,
                                                windowEnd: requestedWindowEnd, calendar: calendar)
            guard !Task.isCancelled else { return } // cancelled refresh publishes nothing
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                // Same-root failure: keep the last successful data on screen and surface a
                // footer note instead of blanking a working grid over a transient error.
                if snap.state == .error, snap.rootPath == self.snapshot.rootPath,
                   snap.windowDays == self.snapshot.windowDays,
                   self.snapshot.state == .ok {
                    self.lastRefreshFailed = true
                } else {
                    self.snapshot = snap
                    self.lastRefreshFailed = false
                }
                self.isLoading = false
                self.running = false
                if self.dirty { self.dirty = false; self.refresh() } // exactly one follow-up
            }
        }
    }
}

@main
struct TokographApp: App {
    @StateObject private var store: UsageStore
    private let windowObserver: NSObjectProtocol?

    init() {
        MeasureMode.runIfRequested()
        let s = UsageStore()
        _store = StateObject(wrappedValue: s)
        // Refresh trigger fallback: key-window notification.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in s.refresh() } // coalescing absorbs double-fires with onAppear
        }
    }

    var body: some Scene {
        MenuBarExtra("Tokograph", systemImage: "square.grid.3x3.middle.filled") {
            HeatmapPopover()
                .environmentObject(store)
                .onAppear { store.refresh() }
        }
        .menuBarExtraStyle(.window)
    }
}
