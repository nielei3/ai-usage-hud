import Foundation

public struct CandidateSet {
    private let clock: UsageClock

    public init(clock: UsageClock) {
        self.clock = clock
    }

    /// Files whose mtime >= min(local midnight, now-5h), recursive, .jsonl only.
    /// Directory names are never consulted — cross-midnight sessions append into
    /// start-day folders, so mtime is the sole admission test.
    public func files(claudeRoot: URL, codexRoot: URL, now: Date) -> [URL] {
        let cutoff = WindowMath.candidateCutoff(now: now, clock: clock)
        var out: [URL] = []
        out += scan(claudeRoot, cutoff: cutoff)
        out += scan(codexRoot, cutoff: cutoff)
        return out
    }

    /// Re-admission test for a single changed file — callers MUST re-derive
    /// eligibility with the NEW mtime on every event, never filter a cached
    /// list, or a session idle >5h stays invisible until the 60s sweep.
    public static func isCandidate(_ url: URL, cutoff: Date) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard let mtime else { return false }
        return mtime >= cutoff
    }

    private func scan(_ root: URL, cutoff: Date) -> [URL] {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in it {
            guard url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true, let mtime = vals?.contentModificationDate, mtime >= cutoff else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }
}
