import Foundation

/// Events flowing out of a recognition backend.
public enum RecognitionEvent: Sendable {
    case speechStarted
    /// Final transcript for one speech segment (or inference pass).
    case transcript(String)
    /// Informational partial/provisional transcript — display only, never counted.
    case partialTranscript(String)
    case speechEnded
    case error(String)
    /// the input device capture is bound to changed (bluetooth connect, etc.)
    case deviceChanged(String)
}

/// A recognition backend: audio in, transcript events out.
/// Implementations: NawahCoreML (primary), future others.
/// The engine never sees audio — backends own the whole audio-to-text path.
public protocol DhikrRecognizer: AnyObject, Sendable {
    var events: AsyncStream<RecognitionEvent> { get }
    func start() async throws
    func stop() async
}
