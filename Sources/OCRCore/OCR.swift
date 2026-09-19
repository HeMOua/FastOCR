import Foundation
import CoreGraphics
import Vision

public struct OCRBlock {
    public let text: String
    public let confidence: Float
    /// Vision normalized coordinates, origin at bottom left.
    public let boundingBox: CGRect
}
public struct OCRResult {
    public let blocks: [OCRBlock]
    public let duration: TimeInterval
    public var text: String { blocks.map(\.text).joined(separator: "\n") }
}
public protocol OCREngine {
    func recognize(image: CGImage) async throws -> OCRResult
}
public struct VisionOCREngine: OCREngine {
    public init() {}
    public func recognize(image: CGImage) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            let start = Date()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let blocks = (request.results ?? []).compactMap { observation -> OCRBlock? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRBlock(text: candidate.string, confidence: candidate.confidence, boundingBox: observation.boundingBox)
            }
            return OCRResult(blocks: blocks, duration: Date().timeIntervalSince(start))
        }.value
    }
}
public enum SelectionGeometry {
    /// Screen-local AppKit coordinates to screenshot pixels (top-left origin).
    public static func pixelRect(selection: CGRect, screenSize: CGSize, imageSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return .zero }
        let clipped = selection.standardized.intersection(CGRect(origin: .zero, size: screenSize))
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        let sx = imageSize.width / screenSize.width
        let sy = imageSize.height / screenSize.height
        return CGRect(x: clipped.minX * sx, y: (screenSize.height - clipped.maxY) * sy,
                      width: clipped.width * sx, height: clipped.height * sy).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}
