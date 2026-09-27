import XCTest
import AVFoundation
@testable import OCRCore

final class AudioTests: XCTestCase {
    func testSilenceIsBoundedAndShortNoiseIsIgnored() {
        var segmenter = AudioSegmenter()
        XCTAssertTrue(segmenter.append([Float](repeating: 0, count: 160_000), at: 1).isEmpty)
        XCTAssertLessThanOrEqual(segmenter.bufferedSampleCount, 3200)
        XCTAssertTrue(segmenter.append([Float](repeating: 0.1, count: 1600), at: 2).isEmpty)
        XCTAssertTrue(segmenter.append([Float](repeating: 0, count: 16_000), at: 3).isEmpty)
    }
    func testPauseEndsPhraseAndTrimsTrailingSilence() {
        var segmenter = AudioSegmenter()
        XCTAssertTrue(segmenter.append([Float](repeating: 0.1, count: 8000), at: 1).isEmpty)
        let segments = segmenter.append([Float](repeating: 0, count: 8000), at: 1.5)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.samples.count, 10_400)
        XCTAssertEqual(segments.first?.index, 1)
    }
    func testContinuousAudioSplitsAndStoppedCallbacksFlush() {
        var segmenter = AudioSegmenter(maximumSeconds: 2)
        let segments = segmenter.append([Float](repeating: 0.1, count: 80_000), at: 5)
        XCTAssertEqual(segments.map(\.samples.count), [32_000, 32_000])
        XCTAssertNil(segmenter.flushIfIdle(at: 5.4))
        XCTAssertEqual(segmenter.flushIfIdle(at: 5.6)?.samples.count, 16_000)
        XCTAssertNil(segmenter.flushIfIdle(at: 6))
        XCTAssertEqual(segmenter.bufferedSampleCount, 0)
    }
    func testInvalidSamplesCannotPoisonEnergyDetection() {
        XCTAssertEqual(AudioSegmenter.rms([.nan, .infinity]), 0)
        var segmenter = AudioSegmenter()
        XCTAssertTrue(segmenter.append([Float](repeating: .nan, count: 16_000), at: 1).isEmpty)
    }
    func testAudioDefaultsAndMigration() throws {
        let settings = try JSONDecoder().decode(SubtitleSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.inputMode, .applicationAudio)
        XCTAssertEqual(settings.audioSegmentSeconds, 3)
        var changed = settings
        changed.inputMode = .screenRegion
        changed.audioApplicationBundleID = "com.example.player"
        XCTAssertEqual(try JSONDecoder().decode(SubtitleSettings.self, from: JSONEncoder().encode(changed)), changed)
    }
    func testRealSpeechWorkerAndCancellationWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["FASTOCR_TEST_SPEECH"] == "1" else {
            throw XCTSkip("Build speech helper and install model, then set FASTOCR_TEST_SPEECH=1")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = LocalSpeechRecognizer(executable: root.appendingPathComponent(".build/speech-build/FastOCRSpeech"))
        try await worker.prepare()
        let file = try AVAudioFile(forReading: root.appendingPathComponent(".build/speech-source/whisper.cpp-1.9.3/samples/jfk.wav"))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        try file.read(into: buffer, frameCount: 48_000)
        let channel = try XCTUnwrap(buffer.floatChannelData)
        let segment = SpeechSegment(samples: Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))), endedAt: 0, index: 1)
        let result = try await worker.recognize(segment, language: .english)
        XCTAssertTrue(result.text.lowercased().contains("americans"), result.text)
        XCTAssertEqual(result.language, "en")
        let cancelled = Task { try await worker.recognize(segment, language: .english) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { }
        try await worker.prepare()
        let silence = try await worker.recognize(.init(samples: [Float](repeating: 0, count: 16_000), endedAt: 0, index: 2), language: .automatic)
        XCTAssertTrue(silence.text.isEmpty)
    }
}
