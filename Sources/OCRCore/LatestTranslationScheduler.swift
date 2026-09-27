import Foundation

/// One current request, with replacement rather than a FIFO backlog.
/// Cancellation and the deadline never wait for an obsolete engine callback.
@MainActor
public final class LatestTranslationScheduler {
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var requestID: UUID?
    private var lastStarted: TimeInterval?
    public init() {}

    public func submit(_ input: TranslationInput, engine: any SubtitleTranslationEngine,
                       timeout: TimeInterval, minimumInterval: TimeInterval = 0,
                       completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let id = UUID()
        requestID = id
        let wait = max(0, (lastStarted ?? -.infinity) + minimumInterval - ProcessInfo.processInfo.systemUptime)
        task = Task { [weak self] in
            do {
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.lastStarted = ProcessInfo.processInfo.systemUptime
                self.deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000)) }
                    catch { return }
                    self?.finish(id, result: .failure(TranslationFailure("本句翻译超时，已跳过；继续等待新字幕。")), completion: completion)
                }
                let result = try await engine.translate(input)
                try Task.checkCancellation()
                self.finish(id, result: .success(result), completion: completion)
            } catch {
                self?.finish(id, result: .failure(error), completion: completion)
            }
        }
    }
    private func finish(_ id: UUID, result: Result<String, Error>, completion: (Result<String, Error>) -> Void) {
        guard requestID == id else { return }
        cancel()
        completion(result)
    }
    public func cancel() {
        requestID = nil
        task?.cancel(); task = nil
        deadline?.cancel(); deadline = nil
    }
    deinit { task?.cancel(); deadline?.cancel() }
}
