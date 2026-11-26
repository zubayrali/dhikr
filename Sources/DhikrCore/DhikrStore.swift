import Foundation

/// A session interrupted mid-way — the "where you stopped" state.
public struct PersistedSession: Codable, Sendable, Equatable {
    public let setId: String
    public let setName: String
    public let counts: [Int]
    public let targets: [Int]
    public let currentStep: Int
    public let startedAt: Date
    public var lastActiveAt: Date

    public init(setId: String, setName: String, counts: [Int], targets: [Int], currentStep: Int, startedAt: Date, lastActiveAt: Date) {
        self.setId = setId
        self.setName = setName
        self.counts = counts
        self.targets = targets
        self.currentStep = currentStep
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
    }
}

/// Per-day aggregate counts, keyed by yyyy-MM-dd.
public struct DayLog: Codable, Sendable, Equatable {
    public var totalByDhikr: [String: Int]
    public var total: Int

    public init(totalByDhikr: [String: Int], total: Int) {
        self.totalByDhikr = totalByDhikr
        self.total = total
    }
}

/// JSON-file persistence in ~/Library/Application Support/Dhikr/.
/// Simple by design — the MVP store. Atomic writes via temp+rename.
public final class DhikrStore: Sendable {

    private let dir: URL

    public init(dir: URL? = nil) {
        if let dir {
            self.dir = dir
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.dir = base.appendingPathComponent("Dhikr", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    // MARK: - unfinished session

    public func saveUnfinished(_ session: PersistedSession) {
        write(session, to: "unfinished-session.json")
    }

    public func loadUnfinished() -> PersistedSession? {
        read(PersistedSession.self, from: "unfinished-session.json")
    }

    public func clearUnfinished() {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("unfinished-session.json"))
    }

    // MARK: - day logs

    public func logCounts(_ byDhikr: [String: Int], on date: Date = Date()) {
        let key = Self.dayKey(date)
        var log = read(DayLog.self, from: "day-\(key).json") ?? DayLog(totalByDhikr: [:], total: 0)
        for (id, n) in byDhikr {
            log.totalByDhikr[id, default: 0] += n
            log.total += n
        }
        write(log, to: "day-\(key).json")
    }

    public func dayLog(for date: Date = Date()) -> DayLog {
        read(DayLog.self, from: "day-\(Self.dayKey(date)).json") ?? DayLog(totalByDhikr: [:], total: 0)
    }

    /// Consecutive days with total > 0 ending today or yesterday.
    public func streak(referenceDate: Date = Date()) -> Int {
        var count = 0
        var day = referenceDate
        // allow today to be empty if yesterday wasn't (streak unbroken until tomorrow)
        if dayLog(for: day).total == 0 {
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        while dayLog(for: day).total > 0 {
            count += 1
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    public static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    // MARK: - io

    private func write<T: Encodable>(_ value: T, to name: String) {
        do {
            let data = try JSONEncoder().encode(value)
            let tmp = dir.appendingPathComponent(name + ".tmp")
            try data.write(to: tmp)
            _ = try? FileManager.default.replaceItemAt(dir.appendingPathComponent(name), withItemAt: tmp)
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
                try? FileManager.default.removeItem(at: tmp)
            }
        } catch {
            NSLog("DhikrStore write failed: \(error)")
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
