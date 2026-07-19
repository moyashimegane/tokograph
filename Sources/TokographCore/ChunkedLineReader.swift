import Foundation

public enum ChunkedLineReader {
    /// Reads `url` in bounded chunks, invoking `body` per complete line (no trailing \n).
    /// Lines exceeding `capBytes` are dropped (skip-to-newline) and counted in the return value.
    /// The final unterminated line, if within cap, is delivered.
    @discardableResult
    public static func forEachLine(url: URL, capBytes: Int = 10 * 1024 * 1024,
                                   chunkBytes: Int = 1 << 20,
                                   _ body: (Data) throws -> Void) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var carry = Data()
        var dropping = false
        var droppedCount = 0
        while true {
            guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
            var start = chunk.startIndex
            while let nl = firstNewline(in: chunk, from: start) {
                if dropping {
                    dropping = false // end of the oversized line
                } else if carry.isEmpty {
                    // Fast path: line fully contained in this chunk — hand the chunk slice
                    // straight to `body` (Data slicing shares storage, no copy) instead of
                    // always staging through `carry`.
                    if nl - start > capBytes { droppedCount += 1 } else {
                        try autoreleasepool { try body(chunk[start..<nl]) }
                    }
                } else {
                    carry.append(chunk[start..<nl])
                    // autoreleasepool: JSONSerialization (invoked from `body` per line) allocates
                    // ObjC objects that otherwise accumulate for the whole file/process (no implicit
                    // pool drain in a plain command-line main()), ballooning RSS on large/many lines.
                    if carry.count > capBytes { droppedCount += 1 } else {
                        try autoreleasepool { try body(carry) }
                    }
                    carry.removeAll(keepingCapacity: true)
                }
                start = chunk.index(after: nl)
            }
            if !dropping {
                carry.append(chunk[start...])
                if carry.count > capBytes { // abandon mid-line, skip to next newline
                    dropping = true; droppedCount += 1
                    carry.removeAll(keepingCapacity: true)
                }
            }
        }
        if !dropping && !carry.isEmpty { try autoreleasepool { try body(carry) } }
        return droppedCount
    }

    /// memchr-based newline search: `Data`'s generic `firstIndex(of:)` has no fast contiguous-storage
    /// override and falls back to an element-by-element Collection scan, which is far slower than a
    /// single memchr call over the (typically 1MB) chunk buffer.
    private static func firstNewline(in data: Data, from start: Data.Index) -> Data.Index? {
        guard start < data.endIndex else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data.Index? in
            let base = raw.baseAddress!
            let offset = start - data.startIndex
            let length = data.endIndex - start
            guard let found = memchr(base + offset, 0x0A, length) else { return nil }
            let foundOffset = UnsafeRawPointer(found) - base
            return data.startIndex + foundOffset
        }
    }
}
