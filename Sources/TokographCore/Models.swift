import Foundation

public struct TokenCounts: Equatable, Sendable {
    public var input: Int64
    public var output: Int64
    public var cacheCreation: Int64
    public var cacheRead: Int64
    public init(input: Int64 = 0, output: Int64 = 0, cacheCreation: Int64 = 0, cacheRead: Int64 = 0) {
        self.input = input; self.output = output
        self.cacheCreation = cacheCreation; self.cacheRead = cacheRead
    }
    public var wideTotal: WideUInt {
        WideUInt(UInt64(input)) + WideUInt(UInt64(output))
            + WideUInt(UInt64(cacheCreation)) + WideUInt(UInt64(cacheRead))
    }
}

public struct UsageRecord: Equatable, Sendable {
    public var timestamp: Date
    public var tokens: TokenCounts
    public var model: String?
    public var project: String
    public var sessionId: String?
    public var messageId: String
    public var requestId: String?
    public init(timestamp: Date, tokens: TokenCounts, model: String?, project: String,
                sessionId: String?, messageId: String, requestId: String?) {
        self.timestamp = timestamp; self.tokens = tokens; self.model = model
        self.project = project; self.sessionId = sessionId
        self.messageId = messageId; self.requestId = requestId
    }
}

public enum LineClass: Equatable, Sendable {
    case usage(UsageRecord)
    case anomalous
    case unrecognizedUsageLike
    case malformed
    case nonUsage
}

public struct ParseDiagnostics: Equatable, Sendable {
    public var unreadableFiles = 0
    public var malformedLines = 0
    public var anomalousLines = 0
    public var unrecognizedUsageLike = 0
    public var dedupCollisions = 0
    public var saturationEvents = 0
    public var futureTimestamps = 0
    public var unknownTokenFieldSeen = false
    public init() {}
    public var isEmpty: Bool {
        unreadableFiles == 0 && malformedLines == 0 && anomalousLines == 0
            && unrecognizedUsageLike == 0 && dedupCollisions == 0
            && saturationEvents == 0 && futureTimestamps == 0 && !unknownTokenFieldSeen
    }
    public mutating func merge(_ o: ParseDiagnostics) {
        unreadableFiles += o.unreadableFiles; malformedLines += o.malformedLines
        anomalousLines += o.anomalousLines; unrecognizedUsageLike += o.unrecognizedUsageLike
        dedupCollisions += o.dedupCollisions; saturationEvents += o.saturationEvents
        futureTimestamps += o.futureTimestamps
        unknownTokenFieldSeen = unknownTokenFieldSeen || o.unknownTokenFieldSeen
    }
}

public enum DataState: Equatable, Sendable {
    case configError, error, formatChanged, empty, noRecentData, ok
}
