import AppKit
import AVFoundation
import ScreenCaptureKit
import OCRCore

struct AudioApplication: Identifiable, Equatable {
    let id: Int32
    let name: String
    let bundleID: String
    var icon: NSImage? { NSRunningApplication(processIdentifier: id)?.icon }
    @MainActor static func running() -> [Self] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return nil }
            return Self(id: app.processIdentifier, name: app.localizedName ?? bundleID, bundleID: bundleID)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Only the selected app is in the filter. We register an audio output only, never a microphone.
final class ApplicationAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Activity: Sendable { case level(Float), dropped(Int) }
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "FastOCR.app-audio", qos: .userInitiated)
    private var segmenter: AudioSegmenter
    private var converter: AVAudioConverter?
    private var timer: DispatchSourceTimer?
    private var lastMeter: TimeInterval = 0
    private var dropped = 0
    private let onActivity: @Sendable (Activity) -> Void
    private let continuation: AsyncThrowingStream<SpeechSegment, Error>.Continuation
    let segments: AsyncThrowingStream<SpeechSegment, Error>
    init(threshold: Float, maximumSeconds: Double, onActivity: @escaping @Sendable (Activity) -> Void) {
        self.onActivity = onActivity
        segmenter = AudioSegmenter(threshold: threshold, maximumSeconds: maximumSeconds)
        var continuation: AsyncThrowingStream<SpeechSegment, Error>.Continuation!
        // Each entry is a complete short phrase, rather than arbitrary raw audio packets.
        segments = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation = $0 }
        self.continuation = continuation
        super.init()
    }
    @MainActor func start(application: AudioApplication) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard NSRunningApplication(processIdentifier: application.id)?.bundleIdentifier == application.bundleID,
              let selected = content.applications.first(where: { $0.processID == application.id && $0.bundleIdentifier == application.bundleID }) else {
            throw TranslationFailure("所选应用已退出或暂时无法捕获，请打开应用后刷新列表。")
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplays }
        let filter = SCContentFilter(display: display, including: [selected], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        // ScreenCaptureKit requires a display filter; no screen output is registered or consumed.
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        if Task.isCancelled { await stop(); throw CancellationError() }
        queue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let segment = self.segmenter.flushIfIdle(at: now) { self.yield(segment) }
                if now - self.lastMeter > 0.4 { self.onActivity(.level(0)) }
            }
            self.timer = timer
            timer.resume()
        }
    }
    @MainActor func stop() async {
        continuation.finish()
        queue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil }
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { continuation.finish(throwing: error) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        do {
            let pcm = try samples(sampleBuffer)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMeter >= 0.15 {
                onActivity(.level(AudioSegmenter.rms(pcm)))
                lastMeter = now
            }
            for segment in segmenter.append(pcm, at: now) { yield(segment) }
        } catch { continuation.finish(throwing: error) }
    }
    private func yield(_ segment: SpeechSegment) {
        if case .dropped = continuation.yield(segment) { dropped += 1; onActivity(.dropped(dropped)) }
    }
    private func samples(_ buffer: CMSampleBuffer) throws -> [Float] {
        guard let description = buffer.formatDescription else { throw TranslationFailure("无法读取应用音频格式。") }
        let source = AVAudioFormat(cmAudioFormatDescription: description)
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(buffer.numSamples)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw TranslationFailure("无法读取应用音频格式。")
        }
        input.frameLength = AVAudioFrameCount(buffer.numSamples)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(buffer.numSamples), into: input.mutableAudioBufferList)
        guard copied == noErr else { throw TranslationFailure("应用音频读取失败（\(copied)）。") }
        if source == target, let data = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(input.frameLength)))
        }
        if converter?.inputFormat != source { converter = AVAudioConverter(from: source, to: target) }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / source.sampleRate)) + 64) else {
            throw TranslationFailure("无法转换应用音频采样率。")
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard result != .error, error == nil, let data = output.floatChannelData else {
            throw TranslationFailure("应用音频转换失败，请重新开始监听。")
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
    deinit { timer?.cancel(); continuation.finish() }
}
