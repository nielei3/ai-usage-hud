import Foundation

public struct TailPosition: Sendable, Equatable {
    /// Byte offset past the trailing fragment retained in this position.
    public var byteOffset: Int
    var partialBytes: Data
    public var partialCarry: String {
        get { String(decoding: partialBytes, as: UTF8.self) }
        set { partialBytes = Data(newValue.utf8) }
    }

    public init(byteOffset: Int = 0, partialCarry: String = "") {
        self.byteOffset = byteOffset
        self.partialBytes = Data(partialCarry.utf8)
    }
}

public struct TailReadResult: Sendable, Equatable {
    public var newLines: [String]
    public var position: TailPosition

    public init(newLines: [String], position: TailPosition) {
        self.newLines = newLines
        self.position = position
    }
}

public enum TailReader {
    public static func read(url: URL, from position: TailPosition) throws -> TailReadResult {
        var lines: [String] = []
        let next = try forEachLine(url: url, from: position) { lines.append($0) }
        return TailReadResult(newLines: lines, position: next)
    }

    /// Emits complete nonempty UTF-8 lines; the returned position retains unfinished bytes.
    public static func forEachLine(
        url: URL,
        from position: TailPosition,
        chunkSize: Int = 1 << 20,
        _ body: (String) throws -> Void
    ) throws -> TailPosition {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let start = size < position.byteOffset ? TailPosition() : position
        var pending = start.partialBytes
        let offset = try readChunks(handle: handle, offset: start.byteOffset, size: size, chunkSize: chunkSize) { chunk, _ in
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let complete = pending.prefix(through: lastNewline)
            // Copy the remainder so it cannot retain the consumed chunk's backing storage.
            pending = pending.subdata(in: pending.index(after: lastNewline)..<pending.endIndex)
            for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                try autoreleasepool {
                    if let text = String(data: Data(line), encoding: .utf8) { try body(text) }
                }
            }
        }
        var next = TailPosition(byteOffset: offset)
        next.partialBytes = pending
        return next
    }

    /// Compatibility collector; callbacks receive bounded chunks and carry their trailing text.
    public static func readData(
        url: URL,
        from position: TailPosition,
        chunkSize: Int = 1 << 20,
        onChunk: (Chunk) throws -> TailReadResult
    ) throws -> TailReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let start = size < position.byteOffset ? TailPosition() : position
        var carry = String(data: start.partialBytes, encoding: .utf8) ?? ""
        var lines: [String] = []
        var undecoded = carry.isEmpty ? start.partialBytes : Data()
        let offset = try readChunks(handle: handle, offset: start.byteOffset, size: size, chunkSize: chunkSize) { chunk, offset in
            undecoded.append(chunk)
            guard let text = String(data: undecoded, encoding: .utf8) else { return }
            let result = try onChunk(.init(text: text, offset: offset + chunk.count - undecoded.count, carry: carry))
            lines += result.newLines
            carry = result.position.partialCarry
            undecoded.removeAll(keepingCapacity: true)
        }
        var next = TailPosition(byteOffset: offset, partialCarry: carry)
        next.partialBytes.append(undecoded)
        return TailReadResult(newLines: lines, position: next)
    }

    public struct Chunk: Sendable {
        public var text: String
        public var offset: Int
        public var carry: String
    }

    private static func readChunks(
        handle: FileHandle, offset: Int, size: Int, chunkSize: Int,
        _ body: (Data, Int) throws -> Void
    ) throws -> Int {
        precondition(chunkSize > 0)
        try handle.seek(toOffset: UInt64(offset))
        var offset = offset
        while offset < size {
            let count = try autoreleasepool { () throws -> Int in
                var chunk = Data()
                let want = min(chunkSize, size - offset)
                while chunk.count < want {
                    let piece = try handle.read(upToCount: want - chunk.count) ?? Data()
                    guard !piece.isEmpty else { break }
                    chunk.append(piece)
                }
                if !chunk.isEmpty { try body(chunk, offset) }
                return chunk.count
            }
            guard count > 0 else { break }
            offset += count
        }
        return offset
    }
}

/// Streams UTF-8 lines, including a final unterminated line at EOF.
public struct StreamingLineReader {
    private let url: URL
    private let chunkSize: Int

    public init(url: URL, chunkSize: Int = 1 << 20) {
        self.url = url
        self.chunkSize = chunkSize
    }

    public func forEachLine(_ body: (String) throws -> Void) throws {
        let position = try TailReader.forEachLine(url: url, from: TailPosition(), chunkSize: chunkSize, body)
        try autoreleasepool {
            if let tail = String(data: position.partialBytes, encoding: .utf8), !tail.isEmpty { try body(tail) }
        }
    }

    public func lines() throws -> [String] {
        var out: [String] = []
        try forEachLine { out.append($0) }
        return out
    }
}
