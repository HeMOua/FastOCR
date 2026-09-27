import XCTest
@testable import OCRCore

final class SubtitleTests: XCTestCase {
    func testStableSubtitleDeduplicatesSpacesAndLineBreaks() {
        var tracker = SubtitleTracker()
        XCTAssertNil(tracker.observe("Hello world", at: 0).text)
        XCTAssertEqual(tracker.observe("Hello\nworld", at: 0.25).text, "Hello world")
        XCTAssertNil(tracker.observe("Hello  world", at: 1).text)
    }
    func testNewCandidateImmediatelyInvalidatesOldTranslation() {
        var tracker = SubtitleTracker()
        _ = tracker.observe("First", at: 0)
        let ready = tracker.observe("First", at: 0.25)
        let next = tracker.observe("Second", at: 0.3)
        XCTAssertNotEqual(ready.version, next.version)
        XCTAssertNil(next.text)
        XCTAssertEqual(tracker.observe("Second", at: 0.6).text, "Second")
    }
    func testBriefOCRNoiseDoesNotLoseAnInFlightSubtitle() {
        var tracker = SubtitleTracker()
        _ = tracker.observe("字幕", at: 0)
        let first = tracker.observe("字幕", at: 0.25)
        _ = tracker.observe("字暮", at: 0.3)
        _ = tracker.observe("字幕", at: 0.4)
        let restored = tracker.observe("字幕", at: 0.65)
        XCTAssertEqual(restored.text, "字幕")
        XCTAssertNotEqual(restored.version, first.version)
    }
    func testBlankClearsAfterGraceAndSameSubtitleCanReturn() {
        var tracker = SubtitleTracker()
        _ = tracker.observe("字幕", at: 0)
        _ = tracker.observe("字幕", at: 0.25)
        XCTAssertFalse(tracker.observe("", at: 0.5).clear)
        XCTAssertTrue(tracker.observe("", at: 1.3).clear)
        _ = tracker.observe("字幕", at: 2)
        XCTAssertEqual(tracker.observe("字幕", at: 2.25).text, "字幕")
    }
    func testGrowingCaptionHasMaximumWait() {
        var tracker = SubtitleTracker()
        for index in 0..<8 { XCTAssertNil(tracker.observe(String(repeating: "字", count: index + 1), at: Double(index) * 0.1).text) }
        XCTAssertNotNil(tracker.observe("字幕不断出现", at: 0.85).text)
    }
    func testLanguageDetectionAndChineseConversion() {
        XCTAssertEqual(SubtitleLanguage.detect("今日はいい天気ですね。"), .japanese)
        XCTAssertEqual(SubtitleLanguage.detect("Where are you going tonight?"), .english)
        XCTAssertEqual(TranslationInput(text: "軟體開發與學習", source: .traditionalChinese, target: .simplifiedChinese).directResult, "软体开发与学习")
        XCTAssertEqual(TranslationInput(text: "我们明天见", source: .simplifiedChinese, target: .traditionalChinese).directResult, "我們明天見")
        XCTAssertEqual(TranslationInput(text: "學習", source: .traditionalChinese, target: .english).localText, "学习")
    }
    func testOfflineChineseConversionNeedsNoRuntime() async throws {
        let engine = OfflineTranslationEngine(root: URL(fileURLWithPath: "/nonexistent"), script: URL(fileURLWithPath: "/nonexistent"))
        let value = try await engine.translate(.init(text: "学习", source: .simplifiedChinese, target: .traditionalChinese))
        XCTAssertEqual(value, "學習")
    }
    func testMissingModelsGiveActionableError() async {
        let engine = OfflineTranslationEngine(root: URL(fileURLWithPath: "/nonexistent"), script: URL(fileURLWithPath: "/nonexistent"))
        do {
            _ = try await engine.translate(.init(text: "Hello", source: .english, target: .japanese))
            XCTFail("Expected missing models")
        } catch { XCTAssertTrue(error.localizedDescription.contains("准备离线模型")) }
    }
    func testRealOfflineWorkerRoundTripWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["FASTOCR_TEST_OFFLINE"] == "1" else {
            throw XCTSkip("Set FASTOCR_TEST_OFFLINE=1 after installing language packs")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = OfflineTranslationEngine(script: root.appendingPathComponent("Resources/Offline/translate_worker.py"))
        let result = try await engine.translate(.init(text: "I will be back in five minutes.", source: .english, target: .traditionalChinese))
        XCTAssertTrue(result.contains("五"), result)
        XCTAssertFalse(result.contains("▁"), result)
        let japanese = try await engine.translate(.init(text: "この電車は東京に行きますか。", source: .japanese, target: .english))
        XCTAssertTrue(japanese.lowercased().contains("tokyo"), japanese)
        // Reuse the same worker and ensure a cancellation does not poison its next request.
        let cancelled = Task { try await engine.translate(.init(text: "今日はいい天気ですね。", source: .japanese, target: .simplifiedChinese)) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { }
        let resumed = try await engine.translate(.init(text: "I will be back in five minutes.", source: .english, target: .simplifiedChinese))
        XCTAssertTrue(resumed.contains("五"), resumed)
    }
    func testCancellationInterruptsBlockedWorkerWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["FASTOCR_TEST_OFFLINE"] == "1" else { throw XCTSkip("Offline runtime required") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("slow_worker.py")
        try "import sys,time,signal,pathlib\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\npathlib.Path(__file__).with_suffix('.ready').touch()\nfor line in sys.stdin:\n time.sleep(3)\n print('{\"text\":\"test\"}', flush=True)\n".write(to: script, atomically: true, encoding: .utf8)
        let engine = OfflineTranslationEngine(script: script)
        let task = Task { try await engine.translate(.init(text: "Hello", source: .english, target: .japanese)) }
        let ready = temporary.appendingPathComponent("slow_worker.ready")
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
