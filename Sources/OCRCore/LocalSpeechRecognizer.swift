import Foundation

public struct SpeechResult: Decodable, Sendable {
    public let text: String
    public let language: String
    public var subtitleLanguage: SubtitleLanguage {
        switch language { case "zh": return .simplifiedChinese; case "ja": return .japanese; default: return .english }
    }
}

/// A persistent native whisper.cpp worker; audio travels through anonymous pipes, never disk.
public final class LocalSpeechRecognizer: @unchecked Sendable {
    public static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastOCR/Speech/ggml-small-q5_1.bin")
    }
    public static func isInstalled() -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size]) as? NSNumber)?.int64Value == 190_085_487
    }
    private let executable: URL
    private let model: URL
    private let queue = DispatchQueue(label: "FastOCR.speech-recognition", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    public init(executable: URL, model: URL = LocalSpeechRecognizer.modelURL) { self.executable = executable; self.model = model }
    public func prepare() async throws {
        _ = try await recognize(SpeechSegment(samples: [Float](repeating: 0, count: 1600), endedAt: 0, index: 0), language: .automatic, timeout: 45)
    }
    public func recognize(_ segment: SpeechSegment, language: SubtitleLanguage, timeout timeoutSeconds: TimeInterval = 15) async throws -> SpeechResult {
        guard segment.samples.count >= 1600, segment.samples.count <= 240_000 else { throw TranslationFailure("音频片段长度不合法。") }
        let cancellation = WorkerCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        try self.startIfNeeded()
                        guard let process = self.process, let input = self.input, let output = self.output else { throw TranslationFailure("无法启动本地语音识别。") }
                        cancellation.attach(process)
                        let timeout = DispatchWorkItem { cancellation.cancel() }
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                        defer { timeout.cancel(); cancellation.detach() }
                        let header = "\(language.modelCode) \(segment.samples.count)\n"
                        try input.write(contentsOf: Data(header.utf8))
                        try segment.samples.withUnsafeBytes { try input.write(contentsOf: Data($0)) }
                        var reply = Data()
                        while reply.count < 65_536 {
                            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else { throw TranslationFailure("语音识别进程已停止或超时。") }
                            if byte.first == 10 { break }
                            reply.append(byte)
                        }
                        try cancellation.check()
                        if let json = try JSONSerialization.jsonObject(with: reply) as? [String: String], let error = json["error"] {
                            throw TranslationFailure(error)
                        }
                        continuation.resume(returning: try JSONDecoder().decode(SpeechResult.self, from: reply))
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
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: model.path) else {
            throw TranslationFailure("请先准备语音模型，并使用包含语音组件的 FastOCR.app。")
        }
        let worker = Process(), incoming = Pipe(), outgoing = Pipe()
        worker.executableURL = executable
        worker.arguments = [model.path]
        worker.standardInput = incoming; worker.standardOutput = outgoing
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        process = worker; input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
    }
    private func stopWorker() {
        if let process, process.isRunning { WorkerCancellation.terminateProcess(process) }
        try? input?.close(); try? output?.close()
        process = nil; input = nil; output = nil
    }
    deinit { stopWorker() }
}
