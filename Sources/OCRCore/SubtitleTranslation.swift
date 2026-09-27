import Foundation
import NaturalLanguage

public enum SubtitleLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "auto", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", english = "en", japanese = "ja"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "自动识别"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
    public var modelCode: String {
        switch self {
        case .simplifiedChinese, .traditionalChinese: return "zh"
        default: return rawValue
        }
    }
    public var recognitionLanguages: [String] {
        switch self {
        case .automatic: return ["ja-JP", "en-US", "zh-Hans", "zh-Hant"]
        case .japanese: return ["ja-JP", "en-US"]
        case .english: return ["en-US"]
        default: return [rawValue, "en-US"]
        }
    }
    public static var targets: [Self] { allCases.filter { $0 != .automatic } }
    public static func detect(_ text: String) -> Self {
        // Kana is a stronger signal than language detection on short, Han-heavy captions.
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .japanese }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .english, .japanese]
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .japanese: return .japanese
        case .traditionalChinese: return .traditionalChinese
        case .simplifiedChinese: return .simplifiedChinese
        default: return .english
        }
    }
    public func normalizeChinese(_ text: String) -> String {
        switch self {
        case .simplifiedChinese: return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        case .traditionalChinese: return text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text
        default: return text
        }
    }
}

public struct TranslationInput: Sendable {
    public let text: String
    public let source: SubtitleLanguage
    public let target: SubtitleLanguage
    public init(text: String, source: SubtitleLanguage, target: SubtitleLanguage) {
        self.text = text
        self.source = source == .automatic ? .detect(text) : source
        self.target = target
    }
    public var localText: String { source.modelCode == "zh" ? SubtitleLanguage.simplifiedChinese.normalizeChinese(text) : text }
    public var directResult: String? { source.modelCode == target.modelCode ? target.normalizeChinese(text) : nil }
}

public protocol SubtitleTranslationEngine {
    func translate(_ input: TranslationInput) async throws -> String
}

public struct TranslationFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Debounces OCR, emits each subtitle once, and invalidates in-flight translations immediately.
public struct SubtitleTracker {
    public struct Update {
        public let version: Int
        public let text: String?
        public let clear: Bool
    }
    public private(set) var version = 0
    private var candidate = ""
    private var candidateText = ""
    private var candidateSince: TimeInterval = 0
    private var pendingSince: TimeInterval?
    private var emitted: String?
    private var emittedVersion = -1
    public init() {}
    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.components(separatedBy: .whitespacesAndNewlines).joined()
    }
    public mutating func observe(_ text: String, at now: TimeInterval) -> Update {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.key(clean)
        if key != candidate {
            candidate = key
            candidateText = clean
            candidateSince = now
            version += 1
            if pendingSince == nil { pendingSince = now }
        }
        if key.isEmpty {
            if now - candidateSince >= 0.7 {
                emitted = nil
                pendingSince = nil
                return Update(version: version, text: nil, clear: true)
            }
        } else if emitted != key || emittedVersion != version, now - candidateSince >= 0.18 || now - (pendingSince ?? now) >= 0.8 {
            emitted = key
            emittedVersion = version
            pendingSince = nil
            return Update(version: version, text: candidateText, clear: false)
        }
        return Update(version: version, text: nil, clear: false)
    }
}

