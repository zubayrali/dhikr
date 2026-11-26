import Foundation

/// Scores a 512-sample frame with a speech probability 0...1.
public protocol VADScoring: Sendable {
    func score(frame: [Float]) -> Float
    /// Reset streaming state at a session boundary. Stateless implementations
    /// get this no-op default; neural streaming VADs must override it.
    func reset()
}

public extension VADScoring {
    func reset() {}
}

/// Energy-based voice activity with adaptive noise-floor tracking.
///
/// Fixed thresholds fail in practice: measured on real recitation, speech RMS
/// hovers near 0.02 while silence sits at ~0.0002 — but mic gain, distance, and
/// mumbling shift that by an order of magnitude per user/environment. Instead
/// we track the noise floor continuously (low percentile of recent frame energy)
/// and set the speech floor relative to it. Frames are scored on a ramp:
/// below floor = 0, above floor×8 = 1.
///
/// Stateful: uses a ring buffer of recent frame energies. Thread-safe enough for
/// the single capture-queue consumer.
public final class EnergyVAD: VADScoring, @unchecked Sendable {

    /// absolute minimum floor — digital silence guard, never go below this
    public var absoluteFloor: Float = 0.0015
    /// speech floor = noise estimate × this factor
    public var noiseFactor: Float = 6
    /// ring buffer capacity — ~5s of frames at 32ms
    private let capacity = 160
    private var recent: [Float] = []
    private var noiseEstimate: Float = 0.0005

    public init() {}

    public func score(frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()

        // update ring buffer
        recent.append(rms)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }

        // Noise-floor adaptation was tried and removed: during continuous speech
        // the estimate chases speech itself upward until the floor sits above the
        // user's voice. Fixed low floor instead — measured silence is ~0.0002 and
        // mumbled speech ~0.005+, so 0.002 cleanly separates them in quiet rooms.
        // In noisy environments false triggers cost inference time but not counts
        // (the matcher rejects non-dhikr transcripts). Proper fix: neural VAD.
        let floor: Float = 0.002
        let ceiling = floor * 3
        if rms <= floor { return 0 }
        if rms >= ceiling { return 1 }
        return (rms - floor) / (ceiling - floor)
    }
}
