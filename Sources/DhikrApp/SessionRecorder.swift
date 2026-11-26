import Foundation

/// Records raw session audio (16kHz mono WAV) + pipeline event log for offline replay.
/// Every real-world miscount becomes a reproducible test case. Local-only, never leaves
/// the device; keeps the most recent sessions only.
final class SessionRecorder: @unchecked Sendable {

    struct Event: Codable {
        let t: TimeInterval   // seconds since recording start
        let kind: String      // "segment", "transcript", "count"
        let detail: String
    }

    private var samples: [Float] = []
    private var events: [Event] = []
    private let startTime = Date()
    private let lock = NSLock()
    private let maxSeconds = 600  // 10 min cap ≈ 19MB

    static let recordingsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Dhikr/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func append(_ pcm: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard samples.count < maxSeconds * 16000 else { return }
        samples.append(contentsOf: pcm)
    }

    func log(_ kind: String, _ detail: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(Event(t: Date().timeIntervalSince(startTime), kind: kind, detail: detail))
    }

    /// Writes WAV + JSONL log, prunes old recordings, returns the wav URL.
    func finalize() -> URL? {
        lock.lock()
        let pcm = samples
        let evts = events
        lock.unlock()
        guard pcm.count > 16000 else { return nil }  // ignore <1s sessions

        let stamp = ISO8601DateFormatter().string(from: startTime).replacingOccurrences(of: ":", with: "-")
        let wavURL = Self.recordingsDir.appendingPathComponent("session-\(stamp).wav")
        let logURL = Self.recordingsDir.appendingPathComponent("session-\(stamp).jsonl")

        writeWav(pcm, to: wavURL)
        let logText = evts.map { evt in
            "{\"t\":\(evt.t),\"kind\":\"\(evt.kind)\",\"detail\":\"\(evt.detail.replacingOccurrences(of: "\"", with: "'"))\"}"
        }.joined(separator: "\n")
        try? logText.write(to: logURL, atomically: true, encoding: .utf8)

        prune(keep: 10)
        return wavURL
    }

    private func prune(keep: Int) {
        let fm = FileManager.default
        func creationDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        guard let files = try? fm.contentsOfDirectory(at: Self.recordingsDir, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.pathExtension == "wav" })
            .sorted(by: { creationDate($0) > creationDate($1) })
        else { return }
        for old in files.dropFirst(keep) {
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: old.deletingPathExtension().appendingPathExtension("jsonl"))
        }
    }

    private func writeWav(_ pcm: [Float], to url: URL) {
        var data = Data()
        let n = pcm.count
        let byteCount = UInt32(n * 2)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // RIFF
        data.appendLE(UInt32(36) + byteCount)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // fmt
        data.appendLE(UInt32(16))      // fmt size
        data.appendLE(UInt16(1))       // PCM
        data.appendLE(UInt16(1))       // mono
        data.appendLE(UInt32(16000))   // rate
        data.appendLE(UInt32(32000))   // byte rate
        data.appendLE(UInt16(2))       // block align
        data.appendLE(UInt16(16))      // bits
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // data
        data.appendLE(byteCount)
        for s in pcm {
            let v = Int16(max(-1, min(1, s)) * 32767)
            data.appendLE(UInt16(bitPattern: v))
        }
        try? data.write(to: url)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }
}
