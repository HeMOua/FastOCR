import XCTest
@testable import OCRCore

final class SubtitleSettingsTests: XCTestCase {
    func testOldSettingsMigrateWithoutLosingDisplayPreferencesOrReusingLLMCredentials() throws {
        let old = Data(#"{"source":"ja","target":"zh-Hant","online":true,"endpoint":"https://old.example/chat/completions","model":"old-model","fontSize":32,"opacity":0.4,"showOriginal":false,"clickThrough":true}"#.utf8)
        let settings = try JSONDecoder().decode(SubtitleSettings.self, from: old)
        XCTAssertEqual(settings.source, .japanese)
        XCTAssertEqual(settings.target, .traditionalChinese)
        XCTAssertEqual(settings.fontSize, 32)
        XCTAssertEqual(settings.opacity, 0.4)
        XCTAssertFalse(settings.showOriginal)
        XCTAssertTrue(settings.clickThrough)
        XCTAssertFalse(settings.online)
        XCTAssertEqual(settings.baiduAppID, "")
        XCTAssertEqual(settings.horizontalAlignment, .center)
    }
    func testTransparentBackgroundAndPlacementRoundTrip() throws {
        var settings = SubtitleSettings()
        settings.opacity = 0
        settings.textOpacity = 0.7
        settings.horizontalAlignment = .right
        settings.verticalAlignment = .bottom
        settings.online = true
        settings.baiduAppID = "123"
        let result = try JSONDecoder().decode(SubtitleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(result, settings)
    }
}
