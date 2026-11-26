import Foundation

/// Speech segmentation state machine over VAD probabilities.
/// Constants proven in production (see docs/research/REPORT-sabbih.md §2.6):
/// start after 3 consecutive voiced frames, 500ms hangover, 300ms pre-roll,
/// 250ms min segment, 15s max segment. Frame = 512 samples = 32ms at 16kHz.
public struct SpeechSegmenter: Sendable {

    public struct Config: Sendable {
        public var threshold: Float = 0.5
        public var startFrames: Int = 3
        public var hangoverMs: Int = 500
        public var preRollMs: Int = 300
        public var maxSegmentMs: Int = 15000
        public var minSegmentMs: Int = 250

        public init() {}

        public static let `default` = Config()
    }

    public enum Output {
        case segment([Float])       // complete speech segment, PCM samples
        case speechStarted
        case speechEnded
    }

    private let config: Config
    private var inSpeech = false
    private var voicedRun = 0
    private var silentRun = 0
    private var segment: [[Float]] = []
    private var segmentEnergies: [Float] = []
    private var preRoll: [[Float]] = []
    private var totalFrames = 0
    private var speechLenAtLastVoiced = 0

    private static let frameMs = 32  // 512 samples at 16kHz

    public init(config: Config = .default) {
        self.config = config
    }

    private func msToFrames(_ ms: Int) -> Int {
        max(1, Int((Double(ms) / Double(Self.frameMs)).rounded()))
    }

    /// Feed one VAD frame. Returns outputs produced by this frame (possibly none).
    public mutating func feed(frame: [Float], speechProbability: Float) -> [Output] {
        var out: [Output] = []
        let voiced = speechProbability >= config.threshold

        if !inSpeech {
            preRoll.append(frame)
            let keep = msToFrames(config.preRollMs) + config.startFrames
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }

            voicedRun = voiced ? voicedRun + 1 : 0
            if voicedRun >= config.startFrames {
                inSpeech = true
                silentRun = 0
                segment = preRoll
                segmentEnergies = preRoll.map { frame in
                    var sq: Float = 0
                    for x in frame { sq += x * x }
                    return (sq / Float(max(1, frame.count))).squareRoot()
                }
                preRoll = []
                totalFrames = voicedRun
                speechLenAtLastVoiced = voicedRun
                out.append(.speechStarted)
            }
            return out
        }

        // in speech
        segment.append(frame)
        var sq: Float = 0
        for x in frame { sq += x * x }
        segmentEnergies.append((sq / Float(max(1, frame.count))).squareRoot())
        totalFrames += 1
        if voiced { speechLenAtLastVoiced = totalFrames }
        if !voiced {
            silentRun += 1
        } else {
            silentRun = 0
        }

        let overMax = totalFrames >= msToFrames(config.maxSegmentMs)
        let silenceEnd = silentRun >= msToFrames(config.hangoverMs)

        if overMax && !silenceEnd {
            // Forced cap cut during continuous speech: a blind cut here slices a
            // repetition in half, and both halves transcribe badly — a measurable
            // count loss on fast recitation. Instead split at the quietest frame
            // in the trailing window — continuous tasbih still has micro-gaps
            // between repetitions, so cuts land between words. The remainder
            // seeds the ongoing segment; no audio is lost or duplicated.
            let len = segment.count
            let searchStart = max(msToFrames(config.minSegmentMs), len - msToFrames(3000))
            let searchEnd = max(searchStart + 1, len - msToFrames(300))
            var cutIndex = len
            var bestEnergy = Float.greatestFiniteMagnitude
            for i in searchStart..<min(searchEnd, segmentEnergies.count) {
                if segmentEnergies[i] < bestEnergy {
                    bestEnergy = segmentEnergies[i]
                    cutIndex = i
                }
            }
            let emitted = segment[0..<cutIndex].flatMap { $0 }
            if cutIndex >= msToFrames(config.minSegmentMs) {
                out.append(.segment(emitted))
            }
            segment = Array(segment[cutIndex...])
            segmentEnergies = Array(segmentEnergies[cutIndex...])
            totalFrames = segment.count
            speechLenAtLastVoiced = totalFrames
            // speech is ongoing: no speechEnded, stay inSpeech
            return out
        }

        if silenceEnd {
            // strip trailing silence-only frames when ending by hangover,
            // but keep it simple: emit as-is (hangover tail aids decoding context)
            if speechLenAtLastVoiced >= msToFrames(config.minSegmentMs) {
                out.append(.segment(segment.flatMap { $0 }))
            }
            segment = []
            segmentEnergies = []
            totalFrames = 0
            speechLenAtLastVoiced = 0
            inSpeech = false
            voicedRun = 0
            silentRun = 0
            out.append(.speechEnded)
        }
        return out
    }

    /// Flush any in-progress segment (e.g. session ended mid-speech).
    public mutating func flush() -> [Output] {
        guard inSpeech, speechLenAtLastVoiced >= msToFrames(config.minSegmentMs) else {
            segment = []
            segmentEnergies = []
            inSpeech = false
            voicedRun = 0
            silentRun = 0
            totalFrames = 0
            speechLenAtLastVoiced = 0
            return []
        }
        let samples = segment.flatMap { $0 }
        segment = []
        totalFrames = 0
        speechLenAtLastVoiced = 0
        inSpeech = false
        voicedRun = 0
        silentRun = 0
        return [.segment(samples), .speechEnded]
    }
}
