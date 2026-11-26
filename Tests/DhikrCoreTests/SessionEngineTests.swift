import XCTest
@testable import DhikrCore

final class SessionEngineTests: XCTestCase {

    func tasbihSet() -> DhikrSet { DhikrLibrary.set("tasbih-after-prayer")! }

    func testSingleDhikrCounting() {
        var engine = SessionEngine(single: DhikrLibrary.dhikr("subhanallah")!, target: 33)
        let events = engine.ingestTranscript("سبحان الله سبحان الله سبحان الله ")
        XCTAssertEqual(engine.currentCount, 3)
        XCTAssertTrue(events.contains(.countChanged(step: 0, count: 3)))
    }

    func testIncrementalIngestion() {
        // transcript arriving in pieces across segment boundaries must count cumulatively
        var engine = SessionEngine(single: DhikrLibrary.dhikr("subhanallah")!, target: 33)
        _ = engine.ingestTranscript("سبحان الله ")
        _ = engine.ingestTranscript("سبحان الله ")
        _ = engine.ingestTranscript("سبحان الله")
        XCTAssertEqual(engine.currentCount, 3)
    }

    func testGuidedSetProgression() {
        var engine = SessionEngine(set: tasbihSet())
        let subhanallah33 = Array(repeating: "سبحان الله", count: 33).joined(separator: " ")
        let events = engine.ingestTranscript(subhanallah33)
        XCTAssertTrue(events.contains(.targetReached(step: 0)))
        XCTAssertTrue(events.contains(.advanced(step: 1, dhikrId: "alhamdulillah")))
        XCTAssertEqual(engine.currentStep, 1)
        XCTAssertFalse(engine.completed)

        let hamd33 = Array(repeating: "الحمد لله", count: 33).joined(separator: " ")
        _ = engine.ingestTranscript(hamd33)
        XCTAssertEqual(engine.currentStep, 2)

        let akbar34 = Array(repeating: "الله أكبر", count: 34).joined(separator: " ")
        let final = engine.ingestTranscript(akbar34)
        XCTAssertTrue(final.contains(.sessionCompleted))
        XCTAssertTrue(engine.completed)
    }

    func testMilestonesFireOnCrossing() {
        var engine = SessionEngine(single: DhikrLibrary.dhikr("istighfar")!, target: 99)
        // 34 at once — crosses the 33 milestone in one jump (Lisanak's exact-hit bug fixed)
        let text = Array(repeating: "أستغفر الله", count: 34).joined(separator: " ")
        let events = engine.ingestTranscript(text)
        XCTAssertTrue(events.contains(.milestone(step: 0, value: 33)))
    }

    func testTapSamePipeline() {
        var engine = SessionEngine(single: DhikrLibrary.dhikr("subhanallah")!, target: 33)
        for _ in 0..<5 { _ = engine.tap() }
        XCTAssertEqual(engine.currentCount, 5)
    }

    func testPauseBlocksCounting() {
        var engine = SessionEngine(single: DhikrLibrary.dhikr("subhanallah")!, target: 33)
        engine.pause()
        _ = engine.ingestTranscript("سبحان الله سبحان الله")
        _ = engine.tap()
        XCTAssertEqual(engine.currentCount, 0)
        engine.resume()
        _ = engine.tap()
        XCTAssertEqual(engine.currentCount, 1)
    }

    func testSalawatVariantsCounted() {
        var engine = SessionEngine(single: DhikrLibrary.dhikr("salawat")!, target: 100)
        let events = engine.ingestTranscript("اللهم صل وسلم على سيدنا محمد ")
        XCTAssertEqual(engine.currentCount, 1)
        _ = events
        _ = engine.ingestTranscript("اللهم صل على محمد ")
        XCTAssertEqual(engine.currentCount, 2)
    }

    func testResumeFromPersisted() {
        var engine = SessionEngine(resuming: tasbihSet(), counts: [33, 20, 0], currentStep: 1)
        XCTAssertEqual(engine.currentStep, 1)
        XCTAssertEqual(engine.currentCount, 20)
        let remaining = Array(repeating: "الحمد لله", count: 13).joined(separator: " ")
        let events = engine.ingestTranscript(remaining)
        XCTAssertTrue(events.contains(.targetReached(step: 1)))
    }

    func testUnrelatedSpeechDoesNotCount() {
        var engine = SessionEngine(single: DhikrLibrary.dhikr("subhanallah")!, target: 33)
        _ = engine.ingestTranscript("السلام عليكم كيف حالك اليوم أخباري")
        XCTAssertEqual(engine.currentCount, 0)
    }

    func testManualAdvanceSkipsStep() {
        var engine = SessionEngine(set: tasbihSet())
        let events = engine.advance()
        XCTAssertEqual(engine.currentStep, 1)
        XCTAssertTrue(events.contains(.advanced(step: 1, dhikrId: "alhamdulillah")))
    }
}
