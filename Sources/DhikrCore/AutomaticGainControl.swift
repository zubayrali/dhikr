import Foundation

/// Streaming automatic gain control for 16kHz mono speech frames.
///
/// The recognizer is amplitude-sensitive in two places: Silero consumes STFT
/// magnitudes directly, and Nawah was trained on ordinary speech levels. AGC
/// normalizes quiet/mumbled speech toward a consistent target before either
/// model sees it, while a hard gain cap prevents the noise floor from being
/// amplified without bound. Gain follows compressor timing: fast attenuation
/// (attack) on loud input, slow recovery (release) back toward higher gain.
///
/// Implemented in DhikrCore as a pure value type so live capture and the replay
/// harness execute bit-for-bit the same pipeline.
public struct AutomaticGainControl: Sendable {

    public struct Config: Sendable {
        public var sampleRate: Int
        public var targetRMS: Float
        public var maximumGainDb: Float
        public var attackMs: Float
        public var releaseMs: Float
        public var peakLimit: Float

        public init(
            sampleRate: Int = 16000,
            targetRMS: Float = 0.07,
            maximumGainDb: Float = 24,
            attackMs: Float = 50,
            releaseMs: Float = 500,
            peakLimit: Float = 0.95
        ) {
            self.sampleRate = sampleRate
            self.targetRMS = targetRMS
            self.maximumGainDb = maximumGainDb
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.peakLimit = peakLimit
        }

        public static let `default` = Config()
    }

    private let config: Config
    /// Smoothed gain at the end of the most recently processed frame.
    public private(set) var currentGain: Float = 1

    public init(config: Config = .default) {
        self.config = config
    }

    /// Process one frame (normally 512 samples / 32ms) and return gained audio.
    /// The frame RMS determines the slow gain rider; interpolation inside the
    /// frame avoids zipper noise at frame boundaries. A soft-knee peak limiter
    /// is the final safety stage, so even abrupt loud onsets never hard-clip.
    public mutating func process(frame: [Float]) -> [Float] {
        guard !frame.isEmpty else { return [] }

        var squareSum: Float = 0
        for sample in frame { squareSum += sample * sample }
        let rms = (squareSum / Float(frame.count)).squareRoot()

        let maximumGain = pow(10 as Float, config.maximumGainDb / 20)
        let desiredGain = min(maximumGain, config.targetRMS / max(rms, 0.000001))

        let frameSeconds = Float(frame.count) / Float(config.sampleRate)
        let tauMs = desiredGain < currentGain ? config.attackMs : config.releaseMs
        let alpha = 1 - exp(-frameSeconds / (tauMs / 1000))

        let startGain = currentGain
        currentGain += (desiredGain - currentGain) * alpha
        let endGain = currentGain

        var output = [Float](repeating: 0, count: frame.count)
        for i in 0..<frame.count {
            let position = Float(i + 1) / Float(frame.count)
            let gain = startGain + (endGain - startGain) * position
            output[i] = softLimit(frame[i] * gain)
        }
        return output
    }

    /// Linear below the knee, tanh-compressed above it. Unlike a hard clamp this
    /// preserves polarity and waveform shape while asymptotically staying below
    /// peakLimit even for input samples already near full scale.
    private func softLimit(_ sample: Float) -> Float {
        let ceiling = config.peakLimit
        let knee = ceiling * 0.9
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let sign: Float = sample >= 0 ? 1 : -1
        let headroom = ceiling - knee
        let compressed = knee + headroom * tanh((magnitude - knee) / headroom)
        return sign * min(ceiling, compressed)
    }
}
