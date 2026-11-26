import Foundation

/// A dhikr phrase the engine can count. `arabic` is the canonical form used for matching;
/// `variants` are alternative accepted forms (people recite salawat in many forms).
public struct Dhikr: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let arabic: String
    public let transliteration: String
    public let defaultTarget: Int
    public let variants: [String]

    public init(id: String, arabic: String, transliteration: String, defaultTarget: Int, variants: [String] = []) {
        self.id = id
        self.arabic = arabic
        self.transliteration = transliteration
        self.defaultTarget = defaultTarget
        self.variants = variants
    }

    /// All compact match forms, longest first (longest-first ordering prevents a short
    /// form consuming the prefix of a longer one).
    public var compactForms: [String] {
        ([arabic] + variants)
            .map { ArabicNormalize.compact($0) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }
}

/// A step in a guided set: one dhikr and the target count for this session.
public struct SetStep: Sendable, Equatable, Codable {
    public let dhikrId: String
    public let target: Int
    public init(dhikrId: String, target: Int) {
        self.dhikrId = dhikrId
        self.target = target
    }
}

public struct DhikrSet: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let steps: [SetStep]
    public init(id: String, name: String, steps: [SetStep]) {
        self.id = id
        self.name = name
        self.steps = steps
    }
}

public enum DhikrLibrary {

    public static let adhkar: [Dhikr] = [
        Dhikr(id: "subhanallah", arabic: "سبحان الله", transliteration: "SubhanAllah", defaultTarget: 33),
        Dhikr(id: "alhamdulillah", arabic: "الحمد لله", transliteration: "Alhamdulillah", defaultTarget: 33),
        Dhikr(id: "allahuakbar", arabic: "الله أكبر", transliteration: "Allahu Akbar", defaultTarget: 34),
        Dhikr(id: "tahlil", arabic: "لا إله إلا الله", transliteration: "La ilaha illa Allah", defaultTarget: 100),
        Dhikr(id: "istighfar", arabic: "أستغفر الله", transliteration: "Astaghfirullah", defaultTarget: 100),
        Dhikr(id: "subhanallah-wabihamdih", arabic: "سبحان الله وبحمده", transliteration: "SubhanAllahi wa bihamdih", defaultTarget: 100),
        Dhikr(id: "subhanallah-alazim", arabic: "سبحان الله العظيم", transliteration: "SubhanAllahil 'Azim", defaultTarget: 100),
        Dhikr(id: "hawqala", arabic: "لا حول ولا قوة إلا بالله", transliteration: "La hawla wa la quwwata illa billah", defaultTarget: 100),
        Dhikr(id: "salawat", arabic: "اللهم صل على محمد", transliteration: "Allahumma salli 'ala Muhammad", defaultTarget: 100, variants: [
            "اللهم صل على سيدنا محمد",
            "اللهم صل على محمد وآله",
            "اللهم صل على محمد وعلى آل محمد",
            "اللهم صل على نبينا محمد",
            "اللهم صل وسلم على سيدنا محمد",
            "اللهم صل وسلم على محمد",
            "اللهم صل وسلم وبارك على سيدنا محمد",
            "اللهم صل وسلم وبارك على نبينا محمد",
            "اللهم صل وسلم وبارك على محمد",
            "صلى الله عليه وسلم",
        ]),
    ]

    public static let sets: [DhikrSet] = [
        DhikrSet(id: "tasbih-after-prayer", name: "Tasbih after prayer", steps: [
            SetStep(dhikrId: "subhanallah", target: 33),
            SetStep(dhikrId: "alhamdulillah", target: 33),
            SetStep(dhikrId: "allahuakbar", target: 34),
        ]),
        DhikrSet(id: "istighfar-100", name: "Istighfar ×100", steps: [
            SetStep(dhikrId: "istighfar", target: 100),
        ]),
        DhikrSet(id: "salawat-100", name: "Salawat ×100", steps: [
            SetStep(dhikrId: "salawat", target: 100),
        ]),
        DhikrSet(id: "subhanallah-wabihamdih-100", name: "SubhanAllahi wa bihamdih ×100", steps: [
            SetStep(dhikrId: "subhanallah-wabihamdih", target: 100),
        ]),
    ]

    public static func dhikr(_ id: String) -> Dhikr? {
        adhkar.first { $0.id == id }
    }

    public static func set(_ id: String) -> DhikrSet? {
        sets.first { $0.id == id }
    }
}
