import XCTest
@testable import DhikrCore

final class NormalizeTests: XCTestCase {

    func testStripsDiacritics() {
        XCTAssertEqual(ArabicNormalize.normalize("سُبْحَانَ اللَّهِ"), "سبحان الله")
    }

    func testUnifiesHamzaVariants() {
        XCTAssertEqual(ArabicNormalize.normalize("أستغفر الله"), "استغفر الله")
        XCTAssertEqual(ArabicNormalize.normalize("إله"), "اله")
    }

    func testTehMarbutaAndAlefMaqsura() {
        // ة → ه, ى → ي
        XCTAssertEqual(ArabicNormalize.compact("ةى"), "هي")
    }

    func testTatweelRemoved() {
        XCTAssertEqual(ArabicNormalize.normalize("سبحـان الله"), "سبحان الله")
    }

    func testCompactRemovesSpaces() {
        XCTAssertEqual(ArabicNormalize.compact("سبحان الله"), "سبحانالله")
    }
}

final class MatcherTests: XCTestCase {

    let subhanallah = ArabicNormalize.compact("سبحان الله")  // سبحانالله (10 chars)

    func testExactCounting() {
        let transcript = ArabicNormalize.compact("سبحان الله سبحان الله سبحان الله")
        let matches = DhikrMatcher.findMatches(compactTranscript: transcript, compactTarget: subhanallah)
        XCTAssertEqual(matches.count, 3)
        XCTAssertTrue(matches.allSatisfy { $0.exact })
    }

    func testBackToBackNoSpaces() {
        // ASR often emits continuous text — compact matching must catch it
        let transcript = "سبحاناللهسبحانالله"
        let matches = DhikrMatcher.findMatches(compactTranscript: transcript, compactTarget: subhanallah)
        XCTAssertEqual(matches.count, 2)
    }

    func testFuzzySingleSubstitution() {
        // one character wrong in one repetition of three
        var text = "سبحانالله" + "سبحاناللة".replacingOccurrences(of: "ة", with: "ه") + "سبحانالله"
        // note: after normalize the ة already became ه in both target and text,
        // so construct a genuine error instead:
        text = "سبحانالله" + "سبحاناللـ"  // last char wrong/dropped
        let transcript = ArabicNormalize.compact(text + "سبحانالله")
        let matches = DhikrMatcher.findMatches(compactTranscript: transcript, compactTarget: subhanallah)
        XCTAssertGreaterThanOrEqual(matches.count, 2, "at least the two clean reps must match")
    }

    func testFuzzyInsertion() {
        // ASR inserted an extra char inside one rep: سبحاننالله
        let transcript = "سبحانالله" + "سبحاننالله" + "سبحانالله"
        let matches = DhikrMatcher.findMatches(compactTranscript: transcript, compactTarget: subhanallah)
        XCTAssertEqual(matches.count, 3, "insertion variant should fuzzy-match")
    }

    func testNoFalsePositivesOnSilence() {
        XCTAssertEqual(DhikrMatcher.findMatches(compactTranscript: "", compactTarget: subhanallah).count, 0)
    }

    func testNoFalsePositivesOnUnrelatedArabic() {
        // unrelated speech must not count
        let transcript = ArabicNormalize.compact("السلام عليكم كيف حالك اليوم")
        XCTAssertEqual(DhikrMatcher.findMatches(compactTranscript: transcript, compactTarget: subhanallah).count, 0)
    }

    func testPartialPhraseNotCounted() {
        // half a dhikr is not a dhikr
        let transcript = "سبحان"
        XCTAssertEqual(DhikrMatcher.findMatches(compactTranscript: transcript, compactTarget: subhanallah).count, 0)
    }

    func testThresholdsAreLengthAware() {
        let short = DhikrMatcher.maxDistance(forTargetLength: 8)
        let long = DhikrMatcher.maxDistance(forTargetLength: 30)
        XCTAssertLessThanOrEqual(short, long, "short phrases must tolerate fewer edits")
    }

    func testMixedExactAndFuzzy() {
        // two clean, one with deletion (missing one char): سبحاناله
        let transcript = "سبحانالله" + "سبحاناله" + "سبحانالله"
        let matches = DhikrMatcher.findMatches(compactTranscript: transcript, compactTarget: subhanallah)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.filter { $0.exact }.count, 2)
    }
}
