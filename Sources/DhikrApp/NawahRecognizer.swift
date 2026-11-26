import Foundation
import AVFoundation
import DhikrCore

/// The recognition backend: mic capture → frames → VAD → segmentation →
/// transcription → transcript events. Inference runs serialized off the audio thread.
final class NawahRecognizer: @unchecked Sendable, DhikrRecognizer {

    private let vad: VADScoring
    private let transcriber: SegmentTranscriber
    private var capture: AudioCapture?
    private var chunker = FrameChunker()
    // 14s cap: speech + 300ms pre-roll + 800ms hangover must fit the preprocessor
    // window (240240 samples ≈ 15s) — worst case 238400 samples at 14s speech.
    private var segmenter = SpeechSegmenter(config: {
        var c = SpeechSegmenter.Config()
        c.maxSegmentMs = 14000
        c.hangoverMs = 800
        c.threshold = 0.3
        return c
    }())
    private var running = false

    private var continuation: AsyncStream<RecognitionEvent>.Continuation
    /// events stream is PER-SESSION — recreated in start(), finished in stopImpl().
    /// Proven experimentally: a second consumer attaching to an already-consumed
    /// AsyncStream receives NOTHING (elements vanish). Sharing one stream across
    /// sessions therefore silently starves every session after the first.
    private(set) var events: AsyncStream<RecognitionEvent>
    private var recorder: SessionRecorder?
    /// smoothed input level 0...1, ~10Hz, for the UI meter
    var onLevel: ((Float) -> Void)?
    /// device uid requested before capture started — applied at start()
    private var pendingDeviceUID: String??

    /// re-target capture at a different input device (live mid-session switching).
    /// Safe before start(): the uid is stored and applied when capture begins.
    func retargetInputDevice(_ uid: String?) {
        pendingDeviceUID = uid
        capture?.switchDevice(uid: uid)
    }

    /// serializes inference so at most one segment is transcribed at a time
    private var inferenceChain: Task<Void, Never>?
    /// serializes start/stop — end-of-session stop() races new-session start()
    /// (both fire from independent Tasks); chaining guarantees execution order
    private var lifecycleChain: Task<Void, Never>?

    init(vad: VADScoring = EnergyVAD(), transcriber: SegmentTranscriber) {
        self.vad = vad
        self.transcriber = transcriber
        var cont: AsyncStream<RecognitionEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    private func makeStream() {
        var cont: AsyncStream<RecognitionEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func start() async throws {
        // wait for any in-flight stop() from the previous session before starting
        await lifecycleChain?.value
        // a stop may still be pending behind task scheduling — give it a brief
        // window to land instead of silently returning into a dead pipeline
        var waited = 0
        while running, waited < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        guard !running else {
            continuation.yield(.error("recognizer busy — lifecycle race"))
            return
        }
        guard await AudioCapture.requestPermission() else {
            continuation.yield(.error("Microphone permission denied — enable in System Settings → Privacy → Microphone"))
            return
        }
        // fresh pipeline state for every session — leftover frames/segmenter state
        // from the previous session corrupt the new one's first seconds
        makeStream()
        inferenceChain = nil
        chunker = FrameChunker()
        // tuned against real continuous fast recitation (eval replay):
        // 800ms hangover bridges mumbled low-energy gaps; 0.3 threshold with the
        // adaptive VAD keeps quiet speech voiced — measured +8 count accuracy
        segmenter = SpeechSegmenter(config: {
            var c = SpeechSegmenter.Config()
            c.maxSegmentMs = 14000
            c.hangoverMs = 800
            c.threshold = 0.3
            return c
        }())
        levelSmoothed = 0
        running = true
        recorder = SessionRecorder()
        recorder?.log("capture", "start")
        let capture = AudioCapture { [weak self] buffer in
            self?.ingest(buffer)
        }
        capture.onDeviceChange = { [weak self] name in
            self?.recorder?.log("device", name)
            self?.continuation.yield(.deviceChanged(name))
        }
        self.capture = capture
        try capture.start(deviceUID: pendingDeviceUID ?? nil)
    }

    func stop() async {
        // chain behind prior lifecycle work, and record the chain so a later start() awaits us
        let prior = lifecycleChain
        let op = Task { [weak self] in
            await prior?.value
            self?.stopImpl()
        }
        lifecycleChain = op
        await op.value
    }

    private func stopImpl() {
        running = false
        capture?.stop()
        capture = nil
        continuation.finish()
        if let url = recorder?.finalize() {
            NSLog("session audio recorded: \(url.path)")
        }
        recorder = nil
        // flush any partial segment through inference so the tail of recitation counts
        let tail = segmenter.flush()
        for output in tail {
            if case .segment(let samples) = output {
                enqueueInference(samples)
            }
        }
    }

    /// forwards session events (counts, milestones) into the recording log
    func logEvent(_ kind: String, _ detail: String) {
        recorder?.log(kind, detail)
    }

    var currentInputDeviceName: String {
        capture?.currentDeviceName ?? ""
    }

    // MARK: - pipeline

    private var levelSmoothed: Float = 0
    private var levelCounter = 0

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard running, let data = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        recorder?.append(samples)

        // input level: RMS normalized to a useful display range, smoothed, ~10Hz updates
        var sq: Float = 0
        for x in samples { sq += x * x }
        let rms = (sq / Float(max(1, samples.count))).squareRoot()
        levelSmoothed = levelSmoothed * 0.7 + rms * 0.3
        levelCounter += 1
        if levelCounter % 5 == 0, let onLevel {
            // 0.08 rms ≈ loud speech → full scale
            onLevel(min(1, levelSmoothed / 0.08))
        }

        let frames = chunker.feed(samples)
        for frame in frames {
            let prob = vad.score(frame: frame)
            for output in segmenter.feed(frame: frame, speechProbability: prob) {
                switch output {
                case .speechStarted:
                    continuation.yield(.speechStarted)
                case .speechEnded:
                    continuation.yield(.speechEnded)
                case .segment(let samples):
                    recorder?.log("segment", "\(samples.count) samples (\(samples.count / 16000)s)")
                    enqueueInference(samples)
                }
            }
        }
    }

    private func enqueueInference(_ samples: [Float]) {
        // chain onto prior inference so segments transcribe in order, one at a time
        let prior = inferenceChain
        inferenceChain = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            do {
                let text = try await self.transcriber.transcribe(samples: samples)
                self.recorder?.log("transcript", text.isEmpty ? "(empty)" : text)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.continuation.yield(.transcript(text))
                }
            } catch {
                self.continuation.yield(.error(error.localizedDescription))
            }
        }
    }
}
