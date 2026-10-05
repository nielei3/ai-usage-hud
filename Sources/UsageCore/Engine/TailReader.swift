import Foundation

public struct TailPosition: Sendable, Equatable {
    /// Byte offset of the next UNREAD byte — points PAST a trailing fragment.
    /// The fragment lives in `partialCarry` and completes on the next read.
    public var byteOffset: Int
    public var partialCarry: String

    public init(byteOffset: Int = 0, partialCarry: String = "") {
        self.byteOffset = byteOffset
        self.partialCarry = partialCarry
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
    /// Incremental read. Semantics: `byteOffset` points past the fragment;
    /// the fragment lives in `partialCarry` and completes on the next read.
    public static func read(url: URL, from position: TailPosition) throws -> TailReadResult {
        try readData(url: url, from: position) { chunk in
            splitLines(carrying: chunk.carry, chunk: chunk.text, byteOffset: chunk.offset)
        }
    }

    /// Truncation (file shrank below the offset) resets to zero so the next
    /// read re-ingests the whole replacement file.
    public static func readData(
        url: URL,
        from position: TailPosition,
        chunkSize: Int = 1 << 20,
        onChunk: (Chunk) throws -> TailReadResult
    ) throws -> TailReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var offset = position.byteOffset
        var carry = position.partialCarry
        if size < offset {
            offset = 0
            carry = ""
        }
        guard size > offset else {
            return TailReadResult(newLines: [], position: TailPosition(byteOffset: offset, partialCarry: carry))
        }
        try handle.seek(toOffset: UInt64(offset))
        var lines: [String] = []
        while offset < size {
            // FileHandle.readData(ofLength:) can SHORT-READ after a backward
            // seek — accumulate until the chunk is full or the file ends.
            var chunk = Data()
            let want = min(chunkSize, size - offset)
            while chunk.count < want {
                let piece = try handle.read(upToCount: want - chunk.count) ?? Data()
                guard !piece.isEmpty else { break }
                chunk.append(piece)
            }
            guard !chunk.isEmpty else { break }
            // A nil UTF-8 decode (boundary inside a multi-byte sequence) yields
            // an empty text: carry threads through, the line completes later.
            let text = String(data: chunk, encoding: .utf8) ?? ""
            let result = try onChunk(.init(text: text, offset: offset, carry: carry))
            lines += result.newLines
            offset += chunk.count
            carry = result.position.partialCarry
        }
        return TailReadResult(
            newLines: lines,
            position: TailPosition(byteOffset: offset, partialCarry: carry)
        )
    }

    public struct Chunk: Sendable {
        public var text: String
        public var offset: Int
        /// Carry from the previous chunk (or file position) — completes this
        /// chunk's first line when it split a boundary.
        public var carry: String
    }

    /// Split one chunk into complete lines. `carry` prepends the first line;
    /// a trailing fragment becomes the outgoing carry. The fragment is NOT
    /// re-read: the caller's offset already advanced past the chunk's bytes.
    private static func splitLines(carrying carry: String, chunk: String, byteOffset: Int) -> TailReadResult {
        let text = carry + chunk
        let complete: Substring
        let carryOut: String
        if let lastNewline = text.lastIndex(of: "\n") {
            complete = text[...lastNewline]
            carryOut = String(text[text.index(after: lastNewline)...])
        } else {
            // No newline anywhere: everything is fragment.
            complete = ""
            carryOut = text
        }
        let lines = complete.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return TailReadResult(
            newLines: lines,
            position: TailPosition(byteOffset: byteOffset + chunk.utf8.count, partialCarry: carryOut)
        )
    }
}

/// Streaming line reader over FileHandle — bounded RSS regardless of file
/// size. Replaces String(contentsOf:) whole-file reads.
public struct StreamingLineReader {
    private let url: URL
    private let chunkSize: Int

    public init(url: URL, chunkSize: Int = 1 << 20) {
        self.url = url
        self.chunkSize = chunkSize
    }

    public func forEachLine(_ body: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            // Split only complete lines: the last (newline-less) element stays
            // pending. A chunk boundary inside a multi-byte UTF-8 character is
            // safe because pending is raw Data — String decoding happens only
            // on newline-complete segments.
            guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let complete = pending.prefix(through: lastNewline)
            pending = pending.suffix(from: pending.index(after: lastNewline))
            for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                if let text = String(data: Data(line), encoding: .utf8) {
                    try body(text)
                }
            }
        }
        if let tail = String(data: pending, encoding: .utf8), !tail.isEmpty {
            try body(tail)
        }
    }

    public func lines() throws -> [String] {
        var out: [String] = []
        try forEachLine { out.append($0) }
        return out
    }
}
