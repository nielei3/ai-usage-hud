import Foundation
import Testing
import UsageCore

@Suite struct StreamingReaderTests {
    private func file(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).jsonl")
        try bytes.write(to: url)
        return url
    }

    private func append(_ bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    @Test func unicodeAcrossChunksAndReadsPreservesBytes() throws {
        let bytes = Data("first\n中文🙂\nlast".utf8)
        let url = try file(bytes.prefix(9))
        defer { try? FileManager.default.removeItem(at: url) }
        var lines: [String] = []
        let first = try TailReader.forEachLine(url: url, from: TailPosition(), chunkSize: 2) { lines.append($0) }
        #expect(lines == ["first"])
        #expect(first.byteOffset == 9)
        try append(bytes.dropFirst(9), to: url)
        let second = try TailReader.forEachLine(url: url, from: first, chunkSize: 1) { lines.append($0) }
        #expect(lines == ["first", "中文🙂"])
        #expect(second.byteOffset == bytes.count)
        #expect(second.partialCarry == "last")
        #expect(try TailReader.read(url: url, from: second).newLines.isEmpty)
        try append(Data("\n".utf8), to: url)
        #expect(try TailReader.read(url: url, from: second).newLines == ["last"])
    }

    @Test func largeBurstAndOversizedLineStayOrdered() throws {
        let oversized = String(repeating: "中", count: 400_000)
        let url = try file(Data("start\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var lines: [String] = []
        let first = try TailReader.forEachLine(url: url, from: TailPosition()) { lines.append($0) }
        try append(Data((oversized + "\n" + String(repeating: "next\n", count: 250_000)).utf8), to: url)
        let last = try TailReader.forEachLine(url: url, from: first, chunkSize: 4096) { lines.append($0) }
        #expect(lines.first == "start")
        #expect(lines[1] == oversized)
        #expect(lines.dropFirst(2).allSatisfy { $0 == "next" })
        #expect(lines.count == 250_002)
        #expect(last.partialCarry.isEmpty)
    }

    @Test func truncationDropsOldCarryAndStandaloneEmitsEOF() throws {
        let url = try file(Data("old\nfragment".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let old = try TailReader.read(url: url, from: TailPosition()).position
        try Data("a\nb".utf8).write(to: url)
        var lines: [String] = []
        let next = try TailReader.forEachLine(url: url, from: old, chunkSize: 1) { lines.append($0) }
        #expect(lines == ["a"])
        #expect(next == TailPosition(byteOffset: 3, partialCarry: "b"))
        #expect(try StreamingLineReader(url: url, chunkSize: 1).lines() == ["a", "b"])
    }

    @Test func chunkCompatibilityResumesIncompleteUTF8Position() throws {
        let bytes = Data("中文🙂\n".utf8)
        let url = try file(bytes.prefix(1))
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try TailReader.forEachLine(url: url, from: TailPosition()) { _ in
            Issue.record("incomplete character emitted")
        }
        try append(bytes.dropFirst(1), to: url)
        let result = try TailReader.readData(url: url, from: first, chunkSize: 2) { chunk in
            let parts = (chunk.carry + chunk.text).components(separatedBy: "\n")
            return TailReadResult(
                newLines: parts.dropLast().filter { !$0.isEmpty },
                position: TailPosition(partialCarry: parts.last!)
            )
        }
        #expect(result.newLines == ["中文🙂"])
        #expect(result.position.byteOffset == bytes.count)
        #expect(result.position.partialCarry.isEmpty)
    }

    @Test func throwingCallbackPropagatesAndAllowsReread() throws {
        enum Stop: Error { case requested }
        let url = try file(Data("one\ntwo\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: Stop.self) {
            try TailReader.forEachLine(url: url, from: TailPosition(), chunkSize: 1) { _ in throw Stop.requested }
        }
        #expect(try TailReader.read(url: url, from: TailPosition()).newLines == ["one", "two"])
    }
}
