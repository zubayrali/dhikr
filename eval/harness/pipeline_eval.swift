// End-to-end pipeline validation: WAV → chunker → VAD → segmenter → CoreML transcriber → matcher → count.
// Validates everything except the microphone itself.
import Foundation
import CoreML

// compiled together with: Sources/DhikrCore/*.swift Sources/DhikrApp/NawahCoreMLTranscriber.swift eval/nawah-coreml/swift-cli/loadwav (inlined below)

func loadWav16k(_ path: String) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var offset = 12
    var sampleRate: UInt32 = 0
    var dataRange: Range<Int>?
    var bits: UInt16 = 0
    var fmt: UInt16 = 0
    while offset + 8 <= data.count {
        let chunkSize = Int(UInt32(data[offset+4]) | UInt32(data[offset+5])<<8 | UInt32(data[offset+6])<<16 | UInt32(data[offset+7])<<24)
        let id4 = data[offset..<offset+4]
        if id4.elementsEqual([0x66,0x6D,0x74,0x20]) {
            fmt = UInt16(data[offset+8]) | UInt16(data[offset+9])<<8
            sampleRate = UInt32(data[offset+12]) | UInt32(data[offset+13])<<8 | UInt32(data[offset+14])<<16 | UInt32(data[offset+15])<<24
            bits = UInt16(data[offset+22]) | UInt16(data[offset+23])<<8
        } else if id4.elementsEqual([0x64,0x61,0x74,0x61]) {
            dataRange = (offset+8)..<min(offset+8+chunkSize, data.count)
        }
        offset += 8 + chunkSize + (chunkSize & 1)
    }
    guard sampleRate == 16000, let range = dataRange else { throw NSError(domain: "wav", code: 1) }
    var frames: [Float]
    if fmt == 1 && bits == 16 {
        let n = (range.upperBound - range.lowerBound) / 2
        frames = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: range.lowerBound).bindMemory(to: Int16.self, capacity: n)
            for i in 0..<n { frames[i] = Float(p[i]) / 32768.0 }
        }
    } else { throw NSError(domain: "wav fmt", code: 2) }
    return frames
}

@main struct PipelineEval {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: pipeline_eval <wav> <dhikrId> [expected]")
            return
        }
        let samples = try loadWav16k(args[1])
        let dhikrId = args[2]
        let expected = args.count > 3 ? Int(args[3]) : nil

        guard let dhikr = DhikrLibrary.dhikr(dhikrId) else {
            print("unknown dhikr \(dhikrId)"); return
        }

        let transcriber = try NawahCoreMLTranscriber(modelsDir: URL(fileURLWithPath: "eval/nawah-coreml/build/compiled"))

        var chunker = FrameChunker()
        var cfg = SpeechSegmenter.Config()
        cfg.maxSegmentMs = 14000
        cfg.hangoverMs = 800
        cfg.threshold = 0.3
        var segmenter = SpeechSegmenter(config: cfg)

        // Default is the live pipeline: AGC → Silero VAD. Environment switches
        // exist only for controlled before/after ablations:
        //   PIPELINE_AGC=0     bypass gain normalization
        //   PIPELINE_VAD=energy  use the old energy VAD
        let environment = ProcessInfo.processInfo.environment
        let useAGC = environment["PIPELINE_AGC"] != "0"
        let useEnergyVAD = environment["PIPELINE_VAD"] == "energy"
        let vad: VADScoring
        if useEnergyVAD {
            vad = EnergyVAD()
        } else {
            vad = try SileroVAD(modelsDir: URL(fileURLWithPath: "eval/silero-coreml/build/compiled"))
        }
        var agc = AutomaticGainControl()
        print("pipeline: vad=\(useEnergyVAD ? "energy" : "silero") agc=\(useAGC ? "on" : "off")")

        var segments: [[Float]] = []
        for rawFrame in chunker.feed(samples) {
            let frame = useAGC ? agc.process(frame: rawFrame) : rawFrame
            for output in segmenter.feed(frame: frame, speechProbability: vad.score(frame: frame)) {
                if case .segment(let s) = output { segments.append(s) }
            }
        }
        for output in segmenter.flush() {
            if case .segment(let s) = output { segments.append(s) }
        }

        print("segments: \(segments.count) (\(segments.map { String(format: "%.1f", Double($0.count)/16000) }.joined(separator: ", "))s)")

        var engine = SessionEngine(single: dhikr, target: 999)
        for (i, seg) in segments.enumerated() {
            let text = try await transcriber.transcribe(samples: seg)
            let events = engine.ingestTranscript(text + " ")
            print("seg\(i): \(text)")
            for e in events {
                if case .countChanged(_, let c) = e { print("  → count now \(c)") }
            }
        }
        let count = engine.counts[0]
        print("COUNT: \(count)\(expected.map { " vs expected \($0) — \($0 == count ? "PASS" : "FAIL")" } ?? "")")
    }
}
