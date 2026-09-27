import XCTest
@testable import OCRCore

@MainActor
final class TranslationSchedulerTests: XCTestCase {
    private func input(_ text: String) -> TranslationInput { .init(text: text, source: .english, target: .japanese) }
    func testLatestStartsWithoutWaitingForOldAndLateResultIsIgnored() async {
        let scheduler = LatestTranslationScheduler(), engine = ControlledTranslation()
        let first = expectation(description: "first started"), second = expectation(description: "latest started"), delivered = expectation(description: "latest delivered")
        engine.onStart = { text in if text == "old" { first.fulfill() } else { second.fulfill() } }
        scheduler.submit(input("old"), engine: engine, timeout: 2) { _ in XCTFail("Obsolete result delivered") }
        await fulfillment(of: [first], timeout: 1)
        scheduler.submit(input("latest"), engine: engine, timeout: 2) { result in
            XCTAssertEqual(try? result.get(), "new result"); delivered.fulfill()
        }
        await fulfillment(of: [second], timeout: 1)
        engine.finish("latest", "new result")
        await fulfillment(of: [delivered], timeout: 1)
        engine.finish("old", "late result")
        await Task.yield()
    }
    func testTimeoutReleasesSlotEvenWhenEngineIgnoresCancellation() async {
        let scheduler = LatestTranslationScheduler(), engine = ControlledTranslation()
        let timeout = expectation(description: "deadline")
        scheduler.submit(input("stuck"), engine: engine, timeout: 0.05) { result in
            if case .failure(let error) = result { XCTAssertTrue(error.localizedDescription.contains("超时")) }
            else { XCTFail("Expected timeout") }
            timeout.fulfill()
        }
        await fulfillment(of: [timeout], timeout: 1)
        let next = expectation(description: "next started"), delivered = expectation(description: "next delivered")
        engine.onStart = { _ in next.fulfill() }
        scheduler.submit(input("next"), engine: engine, timeout: 1) { _ in delivered.fulfill() }
        await fulfillment(of: [next], timeout: 1)
        engine.finish("next", "OK")
        await fulfillment(of: [delivered], timeout: 1)
        engine.finish("stuck", "too late")
        await Task.yield()
    }
    func testRateLimitedWaitingCaptionsAreReplacedNotQueued() async {
        let scheduler = LatestTranslationScheduler(), engine = ControlledTranslation()
        let started = expectation(description: "first started")
        engine.onStart = { _ in started.fulfill() }
        scheduler.submit(input("first"), engine: engine, timeout: 1, minimumInterval: 0.2) { _ in XCTFail("Old delivered") }
        await fulfillment(of: [started], timeout: 1)
        let latest = expectation(description: "latest started")
        engine.onStart = { text in XCTAssertEqual(text, "third"); latest.fulfill() }
        scheduler.submit(input("second"), engine: engine, timeout: 1, minimumInterval: 0.2) { _ in XCTFail("Queued obsolete caption delivered") }
        await Task.yield()
        scheduler.submit(input("third"), engine: engine, timeout: 1, minimumInterval: 0.2) { _ in }
        await fulfillment(of: [latest], timeout: 1)
        XCTAssertEqual(engine.started, ["first", "third"])
        XCTAssertGreaterThanOrEqual(engine.times[1] - engine.times[0], 0.18)
        scheduler.cancel()
        engine.finish("first", "old"); engine.finish("third", "latest")
        await Task.yield()
    }
    func testPauseOrStopSuppressesInFlightCallbacks() async {
        let scheduler = LatestTranslationScheduler(), engine = ControlledTranslation()
        let started = expectation(description: "started")
        engine.onStart = { _ in started.fulfill() }
        scheduler.submit(input("pause"), engine: engine, timeout: 0.05) { _ in XCTFail("Paused callback delivered") }
        await fulfillment(of: [started], timeout: 1)
        scheduler.cancel()
        engine.finish("pause", "late")
        try? await Task.sleep(nanoseconds: 80_000_000)
    }
}

@MainActor
private final class ControlledTranslation: SubtitleTranslationEngine {
    var onStart: ((String) -> Void)?
    var started: [String] = []
    var times: [TimeInterval] = []
    private var continuations: [String: CheckedContinuation<String, Error>] = [:]
    func translate(_ input: TranslationInput) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            continuations[input.text] = continuation
            started.append(input.text); times.append(ProcessInfo.processInfo.systemUptime)
            onStart?(input.text)
        }
    }
    func finish(_ text: String, _ result: String) { continuations.removeValue(forKey: text)?.resume(returning: result) }
}
