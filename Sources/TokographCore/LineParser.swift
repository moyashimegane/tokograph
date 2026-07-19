import Foundation

public enum LineParser {
    static let knownTokenKeys = ["input_tokens", "output_tokens",
                                 "cache_creation_input_tokens", "cache_read_input_tokens"]

    /// Classify one jsonl line into exactly one LineClass.
    /// `unknownTokenField` is set when a recognized usage object carries an unknown `*_tokens` key.
    public static func classify(_ line: Data, project: String,
                                unknownTokenField: inout Bool) -> LineClass {
        guard let obj = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else {
            return .malformed
        }
        guard let dict = obj as? [String: Any] else { return .nonUsage }
        let message = dict["message"] as? [String: Any]
        let usageValue = message?["usage"]
        let hasUsageKey = (message?.keys.contains("usage")) ?? false

        if hasUsageKey {
            guard let usage = usageValue as? [String: Any] else { return .anomalous } // null/string/array/number
            let knownPresent = knownTokenKeys.contains { usage[$0] != nil }
            if !knownPresent {
                // usage object but zero recognized fields → format-drift signal, never a silent 0
                return .unrecognizedUsageLike
            }
            if usage.keys.contains(where: { $0.hasSuffix("_tokens") && !knownTokenKeys.contains($0) }) {
                unknownTokenField = true
            }
            guard dict["type"] as? String == "assistant" else { return .anomalous }
            guard let ts = dict["timestamp"] as? String, let date = parseISO8601(ts) else { return .anomalous }
            guard let mid = message?["id"] as? String else { return .anomalous }
            var counts = TokenCounts()
            for key in knownTokenKeys {
                guard let raw = usage[key] else { continue } // absent = 0, normal
                guard let v = validTokenValue(raw) else { return .anomalous }
                switch key {
                case "input_tokens": counts.input = v
                case "output_tokens": counts.output = v
                case "cache_creation_input_tokens": counts.cacheCreation = v
                default: counts.cacheRead = v
                }
            }
            return .usage(UsageRecord(
                timestamp: date, tokens: counts,
                model: message?["model"] as? String, project: project,
                sessionId: dict["sessionId"] as? String, messageId: mid,
                requestId: dict["requestId"] as? String))
        }

        // No message.usage key: top-level usage-shaped object? (format-drift signal)
        if let topUsage = dict["usage"] as? [String: Any],
           topUsage.keys.contains(where: { $0.hasSuffix("_tokens") }) {
            return .unrecognizedUsageLike
        }
        return .nonUsage
    }

    /// Valid iff integer-typed NSNumber (not bool, not float-parsed), 0...Int64.max.
    private static func validTokenValue(_ raw: Any) -> Int64? {
        guard let n = raw as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        if CFNumberIsFloatType(n) { return nil } // decimals & exponent forms
        let v = n.int64Value
        // Out-of-Int64-range positives parse as float-typed or clamp; guard negatives explicitly.
        guard v >= 0, NSNumber(value: v) == n else { return nil }
        return v
    }

    // Thread-local, not shared static instances: Apple documents Formatter subclasses (DateFormatter,
    // NumberFormatter, ISO8601DateFormatter) as not thread-safe — concurrent `.date(from:)` calls on
    // one shared instance from multiple threads is a data race over their internal mutable state,
    // which is live now that ClaudeCodeSource parses files concurrently. Cached per-thread via
    // Thread.threadDictionary to keep the reuse benefit (avoid re-constructing the formatter on every
    // call) without cross-thread sharing.
    private static func threadLocalFormatters() -> (fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter) {
        let key = "TokographCore.LineParser.isoFormatters"
        let dict = Thread.current.threadDictionary
        if let existing = dict[key] as? (ISO8601DateFormatter, ISO8601DateFormatter) {
            return existing
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        dict[key] = (fractional, plain)
        return (fractional, plain)
    }
    static func parseISO8601(_ s: String) -> Date? {
        let f = threadLocalFormatters()
        return f.fractional.date(from: s) ?? f.plain.date(from: s)
    }
}
