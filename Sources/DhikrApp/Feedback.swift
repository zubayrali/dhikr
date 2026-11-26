import AppKit
import DhikrCore

/// Milestone and progress feedback: subtle sounds + trackpad haptics.
/// - light tick per target-third milestone crossing
/// - success chime at target completion
enum Feedback {
    static func milestone() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        NSSound(named: "Tink")?.play()
    }

    static func targetReached() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSSound(named: "Glass")?.play()
    }

    static func sessionCompleted() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSSound(named: "Hero")?.play()
    }
}
