import Foundation

public enum SessionEvent: Equatable, Sendable {
    case countChanged(step: Int, count: Int)
    case milestone(step: Int, value: Int)        // crossed 33/66 (or target thirds)
    case targetReached(step: Int)
    case advanced(step: Int, dhikrId: String)
    case sessionCompleted
}

/// Counting state machine for a guided dhikr session.
/// Pure logic — no audio, no timing. The app layer feeds transcript text and taps.
///
/// Counting model: the matcher consumes transcript for the CURRENT step's dhikr.
/// Voice and tap are the same pipeline downstream of the engine.
public struct SessionEngine: Sendable {

    public private(set) var steps: [SetStep]
    public private(set) var counts: [Int]
    public private(set) var currentStep: Int
    public private(set) var completed: Bool
    public private(set) var paused: Bool

    /// transcript not yet consumed by the matcher (partial segments arrive in pieces)
    private var pendingTranscript: String = ""
    private var milestonesHit: Set<Int> = []

    public init(set: DhikrSet) {
        self.steps = set.steps
        self.counts = Array(repeating: 0, count: set.steps.count)
        self.currentStep = 0
        self.completed = false
        self.paused = false
    }

    public init(single dhikr: Dhikr, target: Int) {
        self.steps = [SetStep(dhikrId: dhikr.id, target: target)]
        self.counts = [0]
        self.currentStep = 0
        self.completed = false
        self.paused = false
    }

    /// Restore a persisted session (resume where you stopped).
    public init(resuming set: DhikrSet, counts: [Int], currentStep: Int) {
        self.steps = set.steps
        self.counts = counts
        self.currentStep = currentStep
        self.completed = false
        self.paused = false
    }

    public var currentDhikr: Dhikr? {
        guard currentStep < steps.count else { return nil }
        return DhikrLibrary.dhikr(steps[currentStep].dhikrId)
    }

    public var currentCount: Int { counts[currentStep] }
    public var currentTarget: Int { steps[currentStep].target }

    /// Feed recognized transcript text (compact forms matched internally).
    /// Returns events produced by this input.
    public mutating func ingestTranscript(_ text: String) -> [SessionEvent] {
        guard !paused, !completed else { return [] }
        pendingTranscript += text
        return drain()
    }

    /// Manual tap — same pipeline as a voice repetition.
    public mutating func tap() -> [SessionEvent] {
        guard !paused, !completed else { return [] }
        return increment(by: 1)
    }

    public mutating func pause() { paused = true }
    public mutating func resume() { paused = false }

    /// Manually skip to the next step (user finished early).
    public mutating func advance() -> [SessionEvent] {
        guard !completed else { return [] }
        return moveToNextStep()
    }

    // MARK: - internals

    private mutating func drain() -> [SessionEvent] {
        guard let dhikr = currentDhikr else { return [] }
        let compact = ArabicNormalize.compact(pendingTranscript)
        guard !compact.isEmpty else { return [] }

        // Score ALL compact forms and pick the best. Longest-first would be wrong:
        // a longer variant can fuzzy-match across repetition boundaries (tail of one
        // rep + head of the next), consuming extra characters and decapitating the
        // following repetition. Match count is the primary signal — the form the user
        // is actually reciting produces the most matches; exactness breaks ties.
        var total = 0
        var consumedUpTo = 0
        var bestExact = -1
        for form in dhikr.compactForms {
            let matches = DhikrMatcher.findMatches(compactTranscript: compact, compactTarget: form)
            let exactCount = matches.filter(\.exact).count
            guard !matches.isEmpty else { continue }
            if matches.count > total || (matches.count == total && exactCount > bestExact) {
                total = matches.count
                consumedUpTo = matches.last!.end
                bestExact = exactCount
            }
        }
        guard total > 0 else {
            // keep only tail of pending that could be a partial repetition start
            let keep = maxFormLength(dhikr)
            if compact.count > keep * 2 {
                pendingTranscript = String(compact.suffix(keep))
            }
            return []
        }
        // drop consumed text; keep the tail for partial-repetition continuity
        pendingTranscript = String(compact.dropFirst(consumedUpTo))
        return increment(by: total)
    }

    private func maxFormLength(_ dhikr: Dhikr) -> Int {
        dhikr.compactForms.map { $0.count }.max() ?? 10
    }

    private mutating func increment(by n: Int) -> [SessionEvent] {
        var events: [SessionEvent] = []
        let target = steps[currentStep].target
        let before = counts[currentStep]
        let after = before + n
        counts[currentStep] = after
        events.append(.countChanged(step: currentStep, count: after))

        // milestone crossings at one-third and two-thirds of target (33/66 for a 99/100 target)
        for frac in [1, 2] {
            let ms = target * frac / 3
            if ms > 0, before < ms, after >= ms, !milestonesHit.contains(ms) {
                milestonesHit.insert(ms)
                events.append(.milestone(step: currentStep, value: ms))
            }
        }

        if before < target && after >= target {
            events.append(.targetReached(step: currentStep))
            events.append(contentsOf: moveToNextStep())
        }
        return events
    }

    private mutating func moveToNextStep() -> [SessionEvent] {
        if currentStep + 1 < steps.count {
            currentStep += 1
            milestonesHit = []
            return [.advanced(step: currentStep, dhikrId: steps[currentStep].dhikrId)]
        } else {
            completed = true
            return [.sessionCompleted]
        }
    }
}
