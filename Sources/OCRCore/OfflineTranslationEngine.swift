import Foundation
import Darwin

/// Serial pipe worker keeps loaded models warm without blocking Swift's cooperative executor.
public final class OfflineTranslationEngine: SubtitleTranslationEngine, @unchecked Sendable {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastOCR/Offline")
    }
    public static func isInstalled(at root: URL = defaultRoot) -> Bool {
        let files = ["runtime/bin/python"] + ["en_zh", "zh_en", "en_ja", "ja_en"].flatMap {
            ["models/\($0)/model/model.bin", "models/\($0)/sentencepiece.model", "models/\($0)/metadata.json"]
        }
        return files.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    private let root: URL
    private let script: URL
    private let queue = DispatchQueue(label: "FastOCR.offline-translation", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    public init(root: URL = OfflineTranslationEngine.defaultRoot, script: URL) { self.root = root; self.script = script }

    public func translate(_ request: TranslationInput) async throws -> String {
        if let direct = request.directResult { return direct }
        let cancellation = WorkerCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        try self.startIfNeeded()
                        guard let process = self.process, let input = self.input, let output = self.output else {
                            throw TranslationFailure("无法启动离线翻译")
                        }
                        cancellation.attach(process)
                        let timeout = DispatchWorkItem { cancellation.cancel() }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
                        defer { timeout.cancel(); cancellation.detach() }
                        var data = try JSONSerialization.data(withJSONObject: [
                            "text": request.localText, "source": request.source.modelCode, "target": request.target.modelCode
                        ])
                        data.append(10)
                        try input.write(contentsOf: data)
                        var reply = Data()
                        while reply.count < 65_536 {
                            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                                throw TranslationFailure("离线翻译进程已停止或超时，请暂停后重试。")
                            }
                            if byte.first == 10 { break }
                            reply.append(byte)
                        }
                        try cancellation.check()
                        guard let json = try JSONSerialization.jsonObject(with: reply) as? [String: String] else {
                            throw TranslationFailure("离线翻译返回了无效结果")
                        }
                        if let error = json["error"] { throw TranslationFailure(error) }
                        guard let text = json["text"], !text.isEmpty else { throw TranslationFailure("离线模型未返回译文") }
                        continuation.resume(returning: request.target.normalizeChinese(text))
                    } catch {
                        self.stopWorker()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        stopWorker()
        guard Self.isInstalled(at: root) else { throw TranslationFailure("请先在字幕翻译设置中准备离线模型。") }
        let worker = Process()
        worker.executableURL = root.appendingPathComponent("runtime/bin/python")
        worker.arguments = ["-I", "-u", script.path, root.path]
        let incoming = Pipe(), outgoing = Pipe()
        worker.standardInput = incoming
        worker.standardOutput = outgoing
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        process = worker
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
    }
    private func stopWorker() {
        if process?.isRunning == true { process?.terminate() }
        try? input?.close(); try? output?.close()
        process = nil; input = nil; output = nil
    }
    deinit { stopWorker() }
}

final class WorkerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled { terminate(process) }
    }
    func detach() { lock.lock(); process = nil; lock.unlock() }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process { terminate(process) }
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    private func terminate(_ process: Process) {
        Self.terminateProcess(process)
    }
    static func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // Native inference may defer SIGTERM. Bound recovery so its serial pipe cannot block forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
