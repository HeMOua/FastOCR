import AppKit
import ScreenCaptureKit
import CoreImage

/// A bounded stream: slow OCR drops intermediate frames instead of building a backlog.
final class SubtitleCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "FastOCR.subtitle-frames", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let continuation: AsyncThrowingStream<CGImage, Error>.Continuation
    let frames: AsyncThrowingStream<CGImage, Error>
    override init() {
        var continuation: AsyncThrowingStream<CGImage, Error>.Continuation!
        frames = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
        super.init()
    }
    @MainActor func start(_ region: CaptureSelection) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { throw CaptureError.noDisplays }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let rect = region.rect
        config.sourceRect = CGRect(x: rect.minX, y: region.screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        config.width = region.image.width
        config.height = region.image.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 4)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        if Task.isCancelled { await stop(); throw CancellationError() }
    }
    @MainActor func stop() async {
        continuation.finish()
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { continuation.finish(throwing: error) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        if let cgImage = context.createCGImage(image, from: image.extent) { continuation.yield(cgImage) }
    }
}
