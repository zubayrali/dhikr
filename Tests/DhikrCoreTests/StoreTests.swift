import XCTest
@testable import DhikrCore

final class StoreTests: XCTestCase {

    func tempStore() -> DhikrStore {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DhikrStore(dir: tmp)
    }

    func testUnfinishedRoundTrip() {
        let store = tempStore()
        let s = PersistedSession(setId: "tasbih-after-prayer", setName: "Tasbih after prayer",
                                 counts: [33, 20, 0], targets: [33, 33, 34], currentStep: 1,
                                 startedAt: Date(), lastActiveAt: Date())
        store.saveUnfinished(s)
        XCTAssertEqual(store.loadUnfinished(), s)
        store.clearUnfinished()
        XCTAssertNil(store.loadUnfinished())
    }

    func testDayLogAccumulates() {
        let store = tempStore()
        store.logCounts(["subhanallah": 33])
        store.logCounts(["subhanallah": 10, "salawat": 5])
        let log = store.dayLog()
        XCTAssertEqual(log.totalByDhikr["subhanallah"], 43)
        XCTAssertEqual(log.totalByDhikr["salawat"], 5)
        XCTAssertEqual(log.total, 48)
    }

    func testStreakCountsConsecutiveDays() {
        let store = tempStore()
        let today = Date()
        store.logCounts(["subhanallah": 5], on: today)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        store.logCounts(["subhanallah": 5], on: yesterday)
        XCTAssertEqual(store.streak(referenceDate: today), 2)
    }

    func testStreakZeroWhenNoActivity() {
        let store = tempStore()
        XCTAssertEqual(store.streak(), 0)
    }
}
