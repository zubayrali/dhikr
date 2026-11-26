import Foundation
import AppKit
import DhikrCore

/// Owns the session engine + recognizer wiring + persistence. The view layer observes this.
@MainActor
final class SessionController: ObservableObject {
    @Published var engine: SessionEngine?
    @Published var listening = false
    @Published var lastTranscript = ""
    @Published var unfinished: PersistedSession?
    @Published var todayTotal = 0
    @Published var streak = 0
    @Published var voiceAvailable = false
    @Published var audioLevel: Float = 0
    @Published var inputDeviceName = ""
    @Published var inputDevices: [AudioDeviceManager.InputDevice] = []
    @Published var inputUsesSystemDefault = true
    @Published var selectedInputUID: String?

    var onCountChange: ((Int) -> Void)?
    var onMilestone: (() -> Void)?
    var onTargetReached: (() -> Void)?
    /// fired whenever a session (re)starts — used to auto-dismiss the panel
    var onSessionStarted: (() -> Void)?

    /// app-global input device resolution (VoiceInk pattern) — drives capture binding
    let deviceManager = AudioDeviceManager()
    private var recognizer: DhikrRecognizer?
    private var eventTask: Task<Void, Never>?
    private let store = DhikrStore()
    private var sessionStartedAt = Date()
    private var currentSetName = ""

    init() {
        refreshMeta()
        inputDevices = deviceManager.refreshDevices()
        syncModeState()
        deviceManager.onChange = { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
    }

    // MARK: - input device selection

    private func devicesChanged() {
        inputDevices = deviceManager.devices.isEmpty ? deviceManager.refreshDevices() : deviceManager.devices
        syncModeState()
        // re-resolve and re-target capture — even if the resolution didn't change,
        // capture's switchDevice dedupes by uid so this is cheap
        (recognizer as? NawahRecognizer)?.retargetInputDevice(deviceManager.resolveTargetUID())
    }

    private func syncModeState() {
        switch deviceManager.mode {
        case .systemDefault:
            inputUsesSystemDefault = true
            selectedInputUID = nil
        case .custom(let uid, _):
            inputUsesSystemDefault = false
            selectedInputUID = uid
        }
    }

    func selectInputDevice(uid: String?) {
        if let uid {
            deviceManager.selectDevice(uid: uid)
        } else {
            deviceManager.selectSystemDefault()
        }
        syncModeState()
        inputDevices = deviceManager.refreshDevices()
        (recognizer as? NawahRecognizer)?.retargetInputDevice(deviceManager.resolveTargetUID())
    }

    func refreshMeta() {
        unfinished = store.loadUnfinished()
        todayTotal = store.dayLog().total
        streak = store.streak()
    }

    // MARK: - session lifecycle

    func startSession(set: DhikrSet) {
        engine = SessionEngine(set: set)
        sessionStartedAt = Date()
        currentSetName = set.name
        currentSetIdValue = set.id
        store.clearUnfinished()
        unfinished = nil
        startListening()
    }

    func startSingle(_ dhikr: Dhikr, target: Int) {
        engine = SessionEngine(single: dhikr, target: target)
        sessionStartedAt = Date()
        currentSetName = dhikr.transliteration
        currentSetIdValue = "single-\(dhikr.id)-\(target)" 
        store.clearUnfinished()
        unfinished = nil
        startListening()
    }

    func resumeUnfinished() {
        guard let u = unfinished, let set = resolveSet(for: u) else { return }
        engine = SessionEngine(resuming: set, counts: u.counts, currentStep: u.currentStep)
        sessionStartedAt = u.startedAt
        currentSetName = u.setName
        currentSetIdValue = u.setId
        unfinished = nil
        startListening()
    }

    func tap() {
        guard let events = engine?.tap() else { return }
        publish(events)
    }

    func pauseToggle() {
        guard var e = engine else { return }
        if e.paused { e.resume() } else { e.pause() }
        engine = e
        persistProgress()
    }

    func endSession() {
        finalize(persistUnfinished: true)
    }

    // MARK: - recognizer wiring

    private func startListening() {
        onSessionStarted?()
        guard let recognizer else { listening = false; return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do {
                try await recognizer.start()
                await MainActor.run {
                    self?.listening = true
                    if let self, let nawah = recognizer as? NawahRecognizer {
                        let desc = self.engine.map { e in
                            "set=\(self.currentSetId) steps=\(e.steps.map { "\($0.dhikrId):\($0.target)" }.joined(separator: ",")) counts=\(e.counts)"
                        } ?? "no-engine"
                        nawah.logEvent("session", desc)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.listening = false
                    self?.lastTranscript = "mic error: \(error.localizedDescription)"
                }
                return
            }
            for await event in recognizer.events {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    func attachRecognizer(_ r: DhikrRecognizer) {
        recognizer = r
        voiceAvailable = true
        if let nawah = r as? NawahRecognizer {
            nawah.onLevel = { [weak self] level in
                Task { @MainActor in self?.audioLevel = level }
            }
            // bind capture to the manager's current resolution from the start
            nawah.retargetInputDevice(deviceManager.resolveTargetUID())
            // device events become session-recording evidence
            deviceManager.onLog = { [weak nawah] msg in
                nawah?.logEvent("device-manager", msg)
            }
        }
        if engine != nil && !listening {
            startListening()
        }
    }

    private func handle(_ event: RecognitionEvent) {
        switch event {
        case .transcript(let text):
            lastTranscript = text
            if let events = engine?.ingestTranscript(text + " ") {
                if events.isEmpty {
                    (recognizer as? NawahRecognizer)?.logEvent("nomatch", String(text.prefix(80)))
                }
                publish(events)
            }
        case .partialTranscript(let text):
            lastTranscript = text
        case .error(let msg):
            lastTranscript = "error: \(msg)"
        case .deviceChanged(let name):
            inputDeviceName = name
        case .speechStarted, .speechEnded:
            break
        }
    }

    /// Stop capture fire-and-forget, off the terminate path, so AVFoundation
    /// session teardown can't deadlock AppKit termination. Counts persist
    /// continuously, so nothing is lost even if the hard exit follows.
    func shutdownAudio() {
        eventTask?.cancel()
        if let recognizer {
            let r = recognizer
            Task.detached { await r.stop() }
        }
    }

    // MARK: - events + persistence

    private func publish(_ events: [SessionEvent]) {
        var counted = false
        for event in events {
            switch event {
            case .countChanged(_, let count):
                onCountChange?(count)
                counted = true
                (recognizer as? NawahRecognizer)?.logEvent("count", "\(count)")
            case .milestone:
                onMilestone?()
            case .targetReached:
                onTargetReached?()
            case .sessionCompleted:
                finalize(persistUnfinished: false)
                return
            case .advanced:
                break
            }
        }
        if counted { persistProgress() }
    }

    private func persistProgress() {
        guard let engine, !engine.completed else { return }
        let u = PersistedSession(
            setId: currentSetId,
            setName: currentSetName,
            counts: engine.counts,
            targets: engine.steps.map { $0.target },
            currentStep: engine.currentStep,
            startedAt: sessionStartedAt,
            lastActiveAt: Date())
        store.saveUnfinished(u)
        unfinished = u
    }

    private var currentSetIdValue = ""
    private var currentSetId: String { currentSetIdValue }

    /// Reconstruct the session's set from its persisted id:
    /// - library set ids ("tasbih-after-prayer")
    /// - single-dhikr sessions ("single-istighfar-100")
    /// - legacy saves that stored a bare dhikr id ("istighfar") — target from the save itself
    private func resolveSet(for u: PersistedSession) -> DhikrSet? {
        if let set = DhikrLibrary.set(u.setId) { return set }
        var dhikrId: String?
        if u.setId.hasPrefix("single-") {
            let parts = u.setId.split(separator: "-")
            if parts.count >= 2 { dhikrId = String(parts[1]) }
        } else {
            dhikrId = u.setId  // legacy bare dhikr id
        }
        guard let id = dhikrId, let dhikr = DhikrLibrary.dhikr(id) else { return nil }
        let target = u.targets.first ?? 100
        return DhikrSet(id: u.setId, name: u.setName, steps: [SetStep(dhikrId: dhikr.id, target: target)])
    }

    private func finalize(persistUnfinished: Bool) {
        // log today's counts
        if let engine {
            var byDhikr: [String: Int] = [:]
            for (i, step) in engine.steps.enumerated() {
                byDhikr[step.dhikrId, default: 0] += engine.counts[i]
            }
            if byDhikr.values.reduce(0, +) > 0 {
                store.logCounts(byDhikr)
            }
        }
        if persistUnfinished {
            persistProgress()
        } else {
            store.clearUnfinished()
        }
        eventTask?.cancel()
        eventTask = nil
        if let recognizer {
            Task { await recognizer.stop() }
        }
        listening = false
        engine = nil
        onCountChange?(0)
        refreshMeta()
    }
}
