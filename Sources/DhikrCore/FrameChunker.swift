import Foundation

/// Accumulates arbitrary-size PCM buffers and peels off fixed 512-sample frames
/// (32ms at 16kHz — the Silero VAD frame size).
public struct FrameChunker: Sendable {
    public static let frameSize = 512

    private var pending: [Float] = []

    public init() {}

    /// Returns complete 512-sample frames; keeps the remainder.
    public mutating func feed(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var frames: [[Float]] = []
        while pending.count >= Self.frameSize {
            frames.append(Array(pending.prefix(Self.frameSize)))
            pending.removeFirst(Self.frameSize)
        }
        return frames
    }
}
