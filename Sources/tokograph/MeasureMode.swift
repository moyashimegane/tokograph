import Foundation
import TokographCore

enum MeasureMode {
    /// `tokograph --measure`: parse the real local dataset, print wall time + peak RSS, exit.
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--measure") else { return }
        let start = Date()
        let snap = RefreshEngine.runRefresh(
            defaultsValue: UserDefaults.standard.string(forKey: "configRoot"),
            env: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser,
            source: ClaudeCodeSource(), now: Date(), calendar: .current)
        let wall = Date().timeIntervalSince(start)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let peakMB = kr == KERN_SUCCESS ? Double(info.resident_size_max) / 1_048_576 : -1
        print("state=\(snap.state) cells=\(snap.cells.count) wall=\(String(format: "%.2f", wall))s peakRSS=\(String(format: "%.0f", peakMB))MB")
        exit(0)
    }
}
