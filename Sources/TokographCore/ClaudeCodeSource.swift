import Foundation

public struct SourceResult: Sendable {
    public var records: [UsageRecord] = []
    public var diagnostics = ParseDiagnostics()
    public var parsedFileCount = 0
    public var enumeratedFileCount = 0
    public var recognizedUsageLines = 0
    public var capExceeded = false
    public var enumerationFailed = false
    public init() {}
}

public protocol UsageSource: Sendable {
    func collect(root: URL) throws -> SourceResult
}

/// Thread-safe running total, used to bound raw (pre-dedup) record accumulation across parse
/// workers — full record lists must never be accumulated. The 2,000,000-key Deduplicator cap
/// alone cannot prevent OOM here because per-file record arrays accumulate in `fileResults` for
/// every in-flight/completed worker *before* the sequential dedup merge runs; this counter lets
/// the submission loop stop dispatching new files once the raw total crosses the cap, bounding
/// how much can pile up to roughly `cap + (width in-flight files)` rather than unbounded.
private final class RecordCountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private(set) var isExceeded = false
    let cap: Int
    init(cap: Int) { self.cap = cap }
    /// Adds `n` to the running total; returns the updated exceeded state.
    @discardableResult
    func add(_ n: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        total += n
        if total > cap { isExceeded = true }
        return isExceeded
    }
}

public struct ClaudeCodeSource: UsageSource {
    /// Overridable in tests only (internal, `@testable import`); production always uses the
    /// default. Mirrors the Deduplicator's 2,000,000-key cap but applies to raw per-file record
    /// counts *before* dedup (see `RecordCountGate`), since that cap alone doesn't bound memory
    /// accumulated ahead of the sequential merge.
    static var recordCountCap = 2_000_000

    public init() {}

    public func collect(root: URL) throws -> SourceResult {
        var result = SourceResult()
        let projectsDir = root.appendingPathComponent("projects")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return result // empty downstream, not an error
        }
        guard fm.isReadableFile(atPath: projectsDir.path) else {
            result.enumerationFailed = true
            return result
        }
        // Deterministic scan order: enumerate then sort by path (dedup tie-break relies on this).
        // Project name is derived from `en.level` against the *same* (enumerator-resolved) URL's
        // pathComponents rather than compared against a separately-constructed `projectsDir` URL:
        // FileManager's enumerator returns symlink-resolved paths (e.g. macOS /var -> /private/var)
        // while `projectsDir` here stays unresolved, so a cross-URL component-count comparison
        // silently misaligns by the number of resolved segments.
        struct FileEntry { let url: URL; let project: String }
        var entries: [FileEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        if let en = fm.enumerator(at: projectsDir, includingPropertiesForKeys: keys, options: [],
                                  errorHandler: { _, _ in
            result.diagnostics.unreadableFiles += 1
            return true // continue enumerating past this entry
        }) {
            for case let url as URL in en {
                guard url.pathExtension == "jsonl" else { continue }
                guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                      rv.isSymbolicLink != true, rv.isRegularFile == true else { continue }
                let comps = url.pathComponents
                let idx = comps.count - en.level
                let project = (idx >= 0 && idx < comps.count) ? comps[idx] : "unknown"
                entries.append(FileEntry(url: url, project: project))
            }
        } else {
            result.enumerationFailed = true
        }
        entries.sort { $0.url.path < $1.url.path }
        result.enumeratedFileCount = entries.count
        guard !entries.isEmpty else { return result } // avoid baseAddress! on an empty buffer below

        // Per-file parse: each file is independent (own FileHandle, own `unknownField` accumulator,
        // own local record/diagnostics buffer), so files are parsed concurrently across cores. Dedup
        // is NOT thread-safe and its tie-break semantics depend on a deterministic scan order,
        // so results are merged into a single Deduplicator *sequentially*, in the same
        // sorted-path order the old serial loop used — this reproduces byte-identical output to the
        // serial implementation (same insert() call sequence => same dedup/cap/tie-break outcome),
        // just computed faster. Bail out before spending threads on it if already cancelled.
        struct FileResult {
            var records: [UsageRecord] = []
            var diagnostics = ParseDiagnostics()
            var recognizedUsageLines = 0
            var readable = true
            var submitted = false // false = never dispatched (cancelled/cap-stopped before reaching it)
        }
        var dedup = Deduplicator()
        guard !Task.isCancelled else { return result }
        var fileResults = [FileResult](repeating: FileResult(), count: entries.count)
        let recordGate = RecordCountGate(cap: Self.recordCountCap)
        // Bounded worker queue rather than DispatchQueue.concurrentPerform: concurrentPerform borrows
        // the *calling* thread as one of its workers (documented work-stealing behavior), and this
        // large-line JSON workload measurably retains far more resident memory when any of it runs on
        // that thread (empirically ~2-3x peak RSS vs. running entirely on dispatched worker threads —
        // consistent with Darwin malloc's per-thread allocation caches never resetting on a long-lived
        // thread). Capping width also avoids many large-line files' peak moments overlapping at once.
        let width = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        let workQueue = DispatchQueue(label: "tokograph.parse", attributes: .concurrent)
        let gate = DispatchSemaphore(value: width)
        let group = DispatchGroup()
        fileResults.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress! // non-inout pointer: safe to capture in the escaping closure below
            for i in entries.indices {
                if Task.isCancelled { break }
                if recordGate.isExceeded { break } // stop dispatching more files once raw total crosses the cap
                gate.wait()
                workQueue.async(group: group) {
                    defer { gate.signal() }
                    let entry = entries[i]
                    var fr = FileResult()
                    var unknownField = false
                    do {
                        let oversized = try ChunkedLineReader.forEachLine(url: entry.url) { line in
                            switch LineParser.classify(line, project: entry.project, unknownTokenField: &unknownField) {
                            case .usage(let record):
                                fr.recognizedUsageLines += 1
                                fr.records.append(record)
                            case .anomalous: fr.diagnostics.anomalousLines += 1
                            case .unrecognizedUsageLike: fr.diagnostics.unrecognizedUsageLike += 1
                            case .malformed: fr.diagnostics.malformedLines += 1
                            case .nonUsage: break
                            }
                        }
                        fr.diagnostics.malformedLines += oversized
                    } catch {
                        fr.readable = false // parsed prefix (if any) already kept, below
                    }
                    fr.diagnostics.unknownTokenFieldSeen = unknownField
                    fr.submitted = true
                    recordGate.add(fr.records.count)
                    base[i] = fr // disjoint index per task; no two tasks share an `i`
                }
            }
            group.wait()
        }
        for fr in fileResults {
            if Task.isCancelled { break }
            if !fr.submitted { break } // never dispatched (cancelled or cap-stopped) — stop merging here
            result.recognizedUsageLines += fr.recognizedUsageLines
            for record in fr.records {
                if !dedup.insert(record) { result.capExceeded = true }
            }
            result.diagnostics.merge(fr.diagnostics)
            if fr.readable {
                result.parsedFileCount += 1
            } else {
                result.diagnostics.unreadableFiles += 1
            }
            if result.capExceeded { break }
        }
        if recordGate.isExceeded { result.capExceeded = true }
        result.diagnostics.dedupCollisions = dedup.collisions
        result.records = dedup.records
        return result
    }
}
