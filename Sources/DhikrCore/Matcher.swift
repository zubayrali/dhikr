import Foundation

public struct DhikrMatch: Equatable, Sendable {
    public let start: Int   // character offset in compact transcript
    public let end: Int
    public let similarity: Double
    public let exact: Bool
}

/// Counts repetitions of a dhikr in compacted transcript text.
///
/// Design: strict left-to-right positional scanning with fixed-start alignment,
/// mirroring the sequential nature of recitation. At each position, the needle is
/// aligned against a window; if the best alignment meets the distance budget the
/// repetition is counted and scanning continues after it, otherwise the scan
/// advances one character (noise tolerance). This avoids the two classic failure
/// modes: exact-then-fuzzy region splitting misses shortened repetitions, and
/// best-score-anywhere matching swallows earlier imperfect repetitions.
public struct DhikrMatcher: Sendable {

    /// Maximum edit distance accepted, derived from a base similarity and scaled
    /// by target length — short phrases tolerate proportionally fewer edits.
    public static func maxDistance(forTargetLength len: Int, baseSimilarity: Double = 0.75) -> Int {
        let shortfall = max(0, 20 - len)
        let thresh = min(0.95, baseSimilarity + Double(shortfall) * 0.006)
        return Int((1.0 - thresh) * Double(len) + 1e-9)
    }

    public static func findMatches(
        compactTranscript: String,
        compactTarget: String,
        maxDistance: Int? = nil
    ) -> [DhikrMatch] {
        let text = Array(compactTranscript)
        let needle = Array(compactTarget)
        let n = text.count, m = needle.count
        guard m > 0, n >= max(1, m / 2) else { return [] }
        let budget = maxDistance ?? Self.maxDistance(forTargetLength: m)

        var results: [DhikrMatch] = []
        var p = 0
        while p < n {
            let remaining = n - p
            if remaining < m - budget { break }  // not enough text left for even a sloppy match
            let windowLen = Swift.min(remaining, m + budget + 1)
            let window = Array(text[p..<(p + windowLen)])
            if let (dist, consumed) = alignAtStart(window: window, needle: needle), dist <= budget {
                results.append(DhikrMatch(
                    start: p,
                    end: p + consumed,
                    similarity: 1.0 - Double(dist) / Double(m),
                    exact: dist == 0
                ))
                p += max(consumed, 1)
            } else {
                p += 1
            }
        }
        return results
    }

    /// Align needle against the start of window (fixed-start, free-end).
    /// Standard edit distance with unit costs, anchored at position 0 of the window.
    /// Returns (best distance over free end positions, consumed window length) — the
    /// end position minimizing cost, ties broken toward shorter consumption.
    static func alignAtStart(window: [Character], needle: [Character]) -> (dist: Int, consumed: Int)? {
        let n = window.count, m = needle.count
        guard n > 0, m > 0 else { return nil }

        var prev = Array(0...m)  // row i=0: aligning needle[0..<j] to empty text = j deletions
        var best = (dist: prev[m], end: 0)

        for i in 1...n {
            var cur = Array(repeating: 0, count: m + 1)
            cur[0] = i  // empty needle to text prefix = i insertions (anchors start)
            for j in 1...m {
                let cost: Int = window[i - 1] == needle[j - 1] ? 0 : 1
                cur[j] = Swift.min(
                    prev[j] + 1,        // skip window char (insertion in text)
                    cur[j - 1] + 1,     // skip needle char (deletion from text)
                    prev[j - 1] + cost  // match/substitute
                )
            }
            if cur[m] < best.dist {
                best = (cur[m], i)
            }
            prev = cur
        }
        return (best.dist, best.end)
    }
}
