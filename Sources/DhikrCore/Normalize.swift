import Foundation

/// Arabic text normalization for dhikr matching.
/// Table validated in production by both major competitors (see docs/research/).
public enum ArabicNormalize {

    /// Full normalization: NFC, strip diacritics/tatweel, unify letter variants,
    /// strip non-alphanumerics, collapse whitespace, lowercase.
    public static func normalize(_ s: String) -> String {
        var out = s.precomposedStringWithCanonicalMapping
        // Strip Arabic diacritics (harakat), Quranic signs, and tatweel.
        out = out.replacingOccurrences(
            of: "[\u{0610}-\u{061A}\u{064B}-\u{065F}\u{0670}\u{06D6}-\u{06ED}\u{0640}]",
            with: "", options: .regularExpression)

        var result = ""
        result.reserveCapacity(out.count)
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

    /// Compact form: normalized with all spaces removed.
    /// Enables matching back-to-back repetitions regardless of ASR spacing.
    public static func compact(_ s: String) -> String {
        normalize(s).replacingOccurrences(of: " ", with: "")
    }
}
