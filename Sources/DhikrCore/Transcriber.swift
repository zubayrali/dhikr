import Foundation

/// Transcribes one speech segment (16kHz mono Float32) to text.
/// Implementation: NawahCoreML (model artifacts from the conversion pipeline).
public protocol SegmentTranscriber: Sendable {
    func transcribe(samples: [Float]) async throws -> String
}
