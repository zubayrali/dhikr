import XCTest
@testable import DhikrCore

final class SegmenterTests: XCTestCase {

    let frame = [Float](repeating: 0.1, count: 512)

    func feed(_ seg: inout SpeechSegmenter, voicedCount: Int, thenSilent silentCount: Int) -> [SpeechSegmenter.Output] {
        var out: [SpeechSegmenter.Output] = []
        for _ in 0..<voicedCount { out.append(contentsOf: seg.feed(frame: frame, speechProbability: 0.9)) }
        for _ in 0..<silentCount { out.append(contentsOf: seg.feed(frame: frame, speechProbability: 0.1)) }
        return out
    }

    func testEmitsSegmentAfterSpeechThenSilence() {
        var seg = SpeechSegmenter()
        // 10 voiced frames (~320ms > 250ms min) then 16 silent (500ms hangover)
        let out = feed(&seg, voicedCount: 10, thenSilent: 16)
        XCTAssertTrue(out.contains { if case .speechStarted = $0 { return true }; return false })
        XCTAssertTrue(out.contains { if case .segment = $0 { return true }; return false })
        XCTAssertTrue(out.contains { if case .speechEnded = $0 { return true }; return false })
    }

    func testNoEmissionBelowMinLength() {
        var seg = SpeechSegmenter()
        // 4 voiced frames (~128ms < 250ms min) then silence
        let out = feed(&seg, voicedCount: 4, thenSilent: 16)
        XCTAssertFalse(out.contains { if case .segment = $0 { return true }; return false })
    }

    func testStartRequiresConsecutiveVoiced() {
        var seg = SpeechSegmenter()
        // alternating voiced/unvoiced never reaches 3 consecutive
        var out: [SpeechSegmenter.Output] = []
        for _ in 0..<10 {
            out.append(contentsOf: seg.feed(frame: frame, speechProbability: 0.9))
            out.append(contentsOf: seg.feed(frame: frame, speechProbability: 0.1))
        }
        XCTAssertFalse(out.contains { if case .speechStarted = $0 { return true }; return false })
    }

    func testMaxSegmentForcesEmission() {
        var seg = SpeechSegmenter()
        var out: [SpeechSegmenter.Output] = []
        // continuous speech beyond 15s cap (469+ frames)
        for _ in 0..<480 {
            out.append(contentsOf: seg.feed(frame: frame, speechProbability: 0.9))
        }
        XCTAssertTrue(out.contains { if case .segment = $0 { return true }; return false })
    }

    func testPreRollIncludedInSegment() {
        var seg = SpeechSegmenter()
        // 5 frames of silence first (pre-roll candidates), then speech, then silence
        var out: [SpeechSegmenter.Output] = []
        for _ in 0..<5 { out.append(contentsOf: seg.feed(frame: frame, speechProbability: 0.1)) }
        out.append(contentsOf: feed(&seg, voicedCount: 10, thenSilent: 16))
        for o in out {
            if case .segment(let samples) = o {
                // pre-roll frames should be included: more samples than voiced frames alone
                XCTAssertGreaterThan(samples.count, 10 * 512)
                return
            }
        }
        XCTFail("no segment emitted")
    }

    func testFlush() {
        var seg = SpeechSegmenter()
        for _ in 0..<10 { _ = seg.feed(frame: frame, speechProbability: 0.9) }
        let out = seg.flush()
        XCTAssertTrue(out.contains { if case .segment = $0 { return true }; return false })
    }
}

final class SegmenterCapTests: XCTestCase {
    /// Continuous speech past the max-segment cap must split at the quietest
    /// frame in the trailing window — not blindly mid-word — and the remainder
    /// must continue as the next segment (no audio lost).
    func testCapSplitAtQuietestPoint() {
        var cfg = SpeechSegmenter.Config()
        cfg.maxSegmentMs = 2000   // small cap for test speed: 62 frames
        var seg = SpeechSegmenter(config: cfg)
        let loud: Float = 0.5
        // continuous loud speech with a distinct quiet dip at frame 50
        var segments: [(start: Int, count: Int)] = []
        var totalSamplesFed = 0
        for i in 0..<100 {
            let energy: Float = (i == 50) ? 0.02 : loud
            let frame = [Float](repeating: energy, count: 512)
            for output in seg.feed(frame: frame, speechProbability: 0.9) {
                if case .segment(let s) = output {
                    segments.append((totalSamplesFed, s.count))
                }
            }
            totalSamplesFed += 512
        }
        XCTAssertEqual(segments.count, 1, "one forced cut expected")
        // cut should happen near the quiet dip (frame 50 ≈ 25600 samples + pre-roll)
        let cutSample = segments[0].count
        let dipSample = 50 * 512
        XCTAssertLessThan(abs(cutSample - dipSample), 512 * 10,
                          "cut \(cutSample) should be within 10 frames of dip \(dipSample)")
    }
}
