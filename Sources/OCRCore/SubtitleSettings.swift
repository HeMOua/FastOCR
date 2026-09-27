import Foundation

public enum SubtitleHorizontalAlignment: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    public var id: String { rawValue }
    public var title: String { switch self { case .left: return "靠左"; case .center: return "居中"; case .right: return "靠右" } }
}
public enum SubtitleVerticalAlignment: String, Codable, CaseIterable, Identifiable {
    case top, center, bottom
    public var id: String { rawValue }
    public var title: String { switch self { case .top: return "靠上"; case .center: return "居中"; case .bottom: return "靠下" } }
}
public enum TranslationInputMode: String, Codable, CaseIterable, Identifiable {
    case applicationAudio, screenRegion
    public var id: String { rawValue }
    public var title: String { self == .applicationAudio ? "应用音频" : "字幕区域" }
}
public struct SubtitleSettings: Codable, Equatable {
    public var inputMode: TranslationInputMode = .applicationAudio
    public var audioApplicationBundleID = ""
    public var audioSegmentSeconds = 3.0
    public var audioThreshold = 0.006
    public var source: SubtitleLanguage = .automatic
    public var target: SubtitleLanguage = .simplifiedChinese
    public var online = false
    public var baiduAppID = ""
    public var requestInterval = 1.1
    public var translationTimeout = 3.0
    public var fontSize = 24.0
    public var opacity = 0.85
    public var textOpacity = 1.0
    public var horizontalAlignment: SubtitleHorizontalAlignment = .center
    public var verticalAlignment: SubtitleVerticalAlignment = .center
    public var showOriginal = true
    public var clickThrough = false
    public init() {}
    enum CodingKeys: String, CodingKey {
        case inputMode, audioApplicationBundleID, audioSegmentSeconds, audioThreshold,
             source, target, online, baiduAppID, requestInterval, translationTimeout, fontSize, opacity,
             textOpacity, horizontalAlignment, verticalAlignment, showOriginal, clickThrough
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputMode = try c.decodeIfPresent(TranslationInputMode.self, forKey: .inputMode) ?? .applicationAudio
        audioApplicationBundleID = try c.decodeIfPresent(String.self, forKey: .audioApplicationBundleID) ?? ""
        audioSegmentSeconds = min(6, max(2, try c.decodeIfPresent(Double.self, forKey: .audioSegmentSeconds) ?? 3))
        audioThreshold = min(0.03, max(0.002, try c.decodeIfPresent(Double.self, forKey: .audioThreshold) ?? 0.006))
        source = try c.decodeIfPresent(SubtitleLanguage.self, forKey: .source) ?? .automatic
        target = try c.decodeIfPresent(SubtitleLanguage.self, forKey: .target) ?? .simplifiedChinese
        if target == .automatic { target = .simplifiedChinese }
        // Old online settings were for an incompatible LLM provider. Never reuse those credentials.
        online = c.contains(.baiduAppID) ? (try c.decodeIfPresent(Bool.self, forKey: .online) ?? false) : false
        baiduAppID = try c.decodeIfPresent(String.self, forKey: .baiduAppID) ?? ""
        requestInterval = min(5, max(0.1, try c.decodeIfPresent(Double.self, forKey: .requestInterval) ?? 1.1))
        translationTimeout = min(10, max(1, try c.decodeIfPresent(Double.self, forKey: .translationTimeout) ?? 3))
        fontSize = min(40, max(16, try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 24))
        opacity = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.85))
        textOpacity = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .textOpacity) ?? 1))
        horizontalAlignment = try c.decodeIfPresent(SubtitleHorizontalAlignment.self, forKey: .horizontalAlignment) ?? .center
        verticalAlignment = try c.decodeIfPresent(SubtitleVerticalAlignment.self, forKey: .verticalAlignment) ?? .center
        showOriginal = try c.decodeIfPresent(Bool.self, forKey: .showOriginal) ?? true
        clickThrough = try c.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? false
    }
    public static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "subtitleSettings"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "subtitleSettings") }
    }
}
