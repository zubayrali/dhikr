import XCTest
@testable import DhikrCore

final class PipelineTests: XCTestCase {

    func testChunkerPeelsFixedFrames() {
        var c = FrameChunker()
        // feed 1000 samples → one 512 frame + 488 remainder
        var frames = c.feed([Float](repeating: 0.5, count: 1000))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 512)
        // feed 24 more → completes second frame
        frames = c.feed([Float](repeating: 0.5, count: 24))
        XCTAssertEqual(frames.count, 1)
    }

    func testChunkerHandlesArbitrarySplits() {
        var c = FrameChunker()
        // feed in odd-sized buffers, count total frames
        var total = 0
        for size in [100, 700, 33, 512, 2048] {
            total += c.feed([Float](repeating: 0.1, count: size)).count
        }
        // total samples = 3393 → 6 full frames (3072 samples)
        XCTAssertEqual(total, 6)
    }

    func testEnergyVADSilenceVsSpeech() {
        let vad = EnergyVAD()
        let silence = [Float](repeating: 0.0001, count: 512)
        XCTAssertEqual(vad.score(frame: silence), 0)
        // loud frame: rms 0.3 → saturates to 1
        let loud = [Float](repeating: 0.3, count: 512)
        XCTAssertEqual(vad.score(frame: loud), 1)
    }

    func testEndToEndSilenceProducesNoSegments() {
        // 3 seconds of silence through the real pipeline logic → zero segments
        var c = FrameChunker()
        var seg = SpeechSegmenter()
        let vad = EnergyVAD()
        var segments = 0
        let silence = [Float](repeating: Float(0.0001), count: 16000 * 3)
        for frame in c.feed(silence) {
            for output in seg.feed(frame: frame, speechProbability: vad.score(frame: frame)) {
                if case .segment = output { segments += 1 }
            }
        }
        XCTAssertEqual(segments, 0)
    }

    func testEndToEndSpeechBurstProducesSegment() {
        var c = FrameChunker()
        var seg = SpeechSegmenter()
        let vad = EnergyVAD()
        var segments: [[Float]] = []
        // 1s silence, 1s loud "speech", 1s silence — 16kHz mono
        var pcm = [Float](repeating: 0.0001, count: 16000)
        pcm += [Float](repeating: 0.2, count: 16000)
        pcm += [Float](repeating: 0.0001, count: 16000)
        for frame in c.feed(pcm) {
            for output in seg.feed(frame: frame, speechProbability: vad.score(frame: frame)) {
                if case .segment(let s) = output { segments.append(s) }
            }
        }
        XCTAssertEqual(segments.count, 1)
        // segment should contain roughly the speech duration (0.5s min check passes, ~1s speech + padding)
        XCTAssertGreaterThan(segments[0].count, 14000)
        XCTAssertLessThan(segments[0].count, 30000)  // 1s speech + pre-roll + hangover padding
    }
}
