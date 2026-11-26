import Speech
import Foundation

func out(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

out("step 1: querying supportedLocales...")
let locales = SFSpeechRecognizer.supportedLocales()
out("step 1 done: \(locales.count) locales")
let arabic = locales.filter { $0.identifier.hasPrefix("ar") }.map { $0.identifier }.sorted()
out("arabic locales: \(arabic)")

out("step 2: creating recognizer ar-SA...")
if let r = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA")) {
    out("step 2 done: recognizer created")
    out("  isAvailable: \(r.isAvailable)")
    out("  supportsOnDeviceRecognition: \(r.supportsOnDeviceRecognition)")
} else {
    out("step 2 FAIL: nil recognizer")
}

for loc in arabic {
    if let rr = SFSpeechRecognizer(locale: Locale(identifier: loc)) {
        out("  \(loc): available=\(rr.isAvailable) onDevice=\(rr.supportsOnDeviceRecognition)")
    }
}

out("step 3: auth status = \(SFSpeechRecognizer.authorizationStatus().rawValue)")
out("probe complete")
