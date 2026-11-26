import XCTest
@testable import DhikrCore

final class AutomaticGainControlTests: XCTestCase {

    func testQuietSpeechIsAmplifiedTowardTargetRMS() {
        var agc = AutomaticGainControl()
        // 200Hz sine, RMS 0.005 — measured quiet/mumbled speech level.
        let frame = sineFrame(amplitude: 0.00707, frequencyHz: 200)
        var output: [Float] = []
        for _ in 0..<31 {  // ~1s of 32ms frames
            output = agc.process(frame: frame)
        }
        let outRMS = rms(output)
        XCTAssertGreaterThan(outRMS, 0.055, "quiet speech should be boosted toward the 0.07 target")
        XCTAssertLessThan(outRMS, 0.085, "steady quiet speech should not overshoot the target materially")
    }

    func testVeryQuietInputIsCappedAtMaximumGain() {
        var agc = AutomaticGainControl()
        // RMS 0.0005 — above digital silence but far below whispered speech.
        let frame = sineFrame(amplitude: 0.000707, frequencyHz: 200)
        var output: [Float] = []
        for _ in 0..<62 {  // ~2s: enough time for release to reach the cap
            output = agc.process(frame: frame)
        }
        let inRMS = rms(frame)
        let outRMS = rms(output)
        let maxLinearGain = pow(10.0, 24.0 / 20.0)
        XCTAssertLessThanOrEqual(outRMS / inRMS, Float(maxLinearGain) * 1.02)
        XCTAssertGreaterThan(outRMS, inRMS * 8, "the cap should still allow a substantial whisper boost")
    }

    func testLoudSpeechIsAttenuatedQuickly() {
        var agc = AutomaticGainControl()
        // Loud sustained speech: RMS ≈ 0.64.
        let frame = sineFrame(amplitude: 0.9, frequencyHz: 200)
        var output: [Float] = []
        for _ in 0..<5 {  // ~160ms, beyond the 50ms attack time
            output = agc.process(frame: frame)
        }
        let outRMS = rms(output)
        XCTAssertLessThan(outRMS, 0.16, "loud input should be attenuated rather than left near full scale")
        XCTAssertGreaterThan(outRMS, 0.04, "attenuation should still approach the speech target, not mute the input")
    }

    func testPeakLimiterNeverProducesClipping() {
        var agc = AutomaticGainControl()
        let frame = sineFrame(amplitude: 0.99, frequencyHz: 200)
        for _ in 0..<8 {
            let output = agc.process(frame: frame)
            XCTAssertLessThanOrEqual(output.map(abs).max() ?? 0, 1.0)
        }
    }

    func testEmptyFrameStaysEmpty() {
        var agc = AutomaticGainControl()
        XCTAssertEqual(agc.process(frame: []), [])
    }

    // MARK: - independent fixtures

    private func sineFrame(amplitude: Float, frequencyHz: Float, count: Int = 512) -> [Float] {
        (0..<count).map { i in
            amplitude * sin(2 * Float.pi * frequencyHz * Float(i) / 16000)
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
