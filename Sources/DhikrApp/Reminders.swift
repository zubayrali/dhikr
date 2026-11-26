import AppKit
import UserNotifications
import DhikrCore

/// Gentle daily reminder: fires once per day at a user-chosen hour if no dhikr
/// was counted yet today, or if there's an unfinished session waiting.
/// Mindful, not noisy — one notification max per day.
@MainActor
final class ReminderManager {
    static let shared = ReminderManager()
    private let center = UNUserNotificationCenter.current()
    private let reminderId = "daily-dhikr-reminder"

    /// hour of day for the reminder, 22 = after Isha-ish default
    var reminderHour: Int {
        get { UserDefaults.standard.integer(forKey: "reminderHour") == 0 ? 21 : UserDefaults.standard.integer(forKey: "reminderHour") }
        set { UserDefaults.standard.set(newValue, forKey: "reminderHour") }
    }
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "remindersEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "remindersEnabled") }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Reschedule the daily reminder. Call on launch and after each session ends.
    func reschedule(store: DhikrStore = DhikrStore()) {
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        if let u = store.loadUnfinished() {
            let total = u.counts.reduce(0, +)
            let target = u.targets.reduce(0, +)
            content.title = "Your tasbih is waiting"
            content.body = "You left off at \(total)/\(target) of \(u.setName). Pick up where you stopped?"
        } else {
            content.title = "A moment of dhikr"
            content.body = "No adhkar counted yet today. Even 33 subhanAllah takes two minutes."
        }
        content.sound = .default

        var components = DateComponents()
        components.hour = reminderHour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: reminderId, content: content, trigger: trigger)
        center.add(request)
    }
}
