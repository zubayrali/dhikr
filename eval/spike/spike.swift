import Speech
import Foundation

// MARK: - RE-derived normalization (Sabbih/Lisanak validated table)
func normalizeArabic(_ s: String) -> String {
    var out = s.precomposedStringWithCanonicalMapping
    // strip Arabic diacritics, signs, tatweel
    out = out.replacingOccurrences(of: "[\\u{0610}-\\u{061A}\\u{064B}-\\u{065F}\\u{0670}\\u{06D6}-\\u{06ED}\\u{0640}]", with: "", options: .regularExpression)
    var result = ""
    for ch in out {
        switch ch {
        case "أ", "إ", "آ", "ٱ", "ٲ": result.append("ا")
        case "ى", "ی", "ئ": result.append("ي")
        case "ة", "ۃ", "ھ", "ہ": result.append("ه")
        case "ؤ": result.append("و")
        case "ک": result.append("ك")
        default: result.append(ch)
        }
    }
    result = result.replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]", with: " ", options: .regularExpression)
    result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return result.trimmingCharacters(in: .whitespaces).lowercased()
}
func compact(_ s: String) -> String { normalizeArabic(s).replacingOccurrences(of: " ", with: "") }

// exact substring multi-count (Lisanak-style) on compacted text
func countOccurrences(needle: String, haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0, start = haystack.startIndex
    while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
        count += 1
        start = range.upperBound
    }
    return count
}

print("=== Dhikr recognition spike ===")
print("supportedLocales containing ar:")
for loc in SFSpeechRecognizer.supportedLocales().filter({ $0.identifier.hasPrefix("ar") }).sorted(by: { $0.identifier < $1.identifier }) {
    print("  \(loc.identifier)")
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA")) else {
    print("FATAL: no recognizer for ar-SA"); exit(1)
}
print("\nar-SA recognizer available: \(recognizer.isAvailable)")
print("ar-SA supportsOnDeviceRecognition: \(recognizer.supportsOnDeviceRecognition)")

let sema = DispatchSemaphore(value: 0)
var authStatus = SFSpeechRecognizer.authorizationStatus()
print("authorizationStatus: \(authStatus.rawValue) (3=authorized)")
if authStatus == .notDetermined {
    print("requesting authorization — watch for a system prompt...")
    SFSpeechRecognizer.requestAuthorization { status in
        authStatus = status
        sema.signal()
    }
    sema.wait()
    print("authorization now: \(authStatus.rawValue)")
}
guard authStatus == .authorized else {
    print("FATAL: speech recognition not authorized"); exit(1)
}

// MARK: - transcribe corpus files
let corpusDir = "../corpus"
let tests: [(file: String, phrase: String, expect: Int)] = [
    ("slow10.wav", "سبحان الله", 10),
    ("fast33.wav", "سبحان الله", 33),
    ("mixed34.wav", "سبحان الله", 11),
]

for contextual in [false, true] {
    print("\n--- contextualStrings: \(contextual ? "ON" : "off") ---")
    for t in tests {
        let url = URL(fileURLWithPath: "\(corpusDir)/\(t.file)")
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        if contextual { request.contextualStrings = ["سبحان الله", "الحمد لله", "الله أكبر", "أستغفر الله", "لا إله إلا الله", "اللهم صل على محمد"] }
        let done = DispatchSemaphore(value: 0)
        var finalText = ""
        var err: Error? = nil
        recognizer.recognitionTask(with: request) { result, error in
            if let r = result, r.isFinal { finalText = r.bestTranscription.formattedString; done.signal() }
            if error != nil { err = error; done.signal() }
        }
        done.wait()
        if let e = err {
            print("\(t.file): ERROR \(e.localizedDescription)")
            continue
        }
        let c = countOccurrences(needle: compact(t.phrase), haystack: compact(finalText))
        print("\(t.file): counted \(c)/\(t.expect) \(c == t.expect ? "✓" : "✗")")
        print("  transcript: \(finalText)")
    }
}
