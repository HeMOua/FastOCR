import XCTest
import AppKit
@testable import OCRCore

final class OCRCoreTests: XCTestCase {
    func testRetinaSelectionFlipsOrigin() {
        let rect = SelectionGeometry.pixelRect(selection: CGRect(x: 100, y: 200, width: 300, height: 100),
            screenSize: CGSize(width: 1440, height: 900), imageSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(rect, CGRect(x: 200, y: 1200, width: 600, height: 200))
    }
    func testSelectionClipsAtScreenEdges() {
        let rect = SelectionGeometry.pixelRect(selection: CGRect(x: -10, y: 80, width: 50, height: 40),
            screenSize: CGSize(width: 100, height: 100), imageSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 80, height: 40))
    }
    func testExternalScreenUsesItsOwnScale() {
        let rect = SelectionGeometry.pixelRect(selection: CGRect(x: 20, y: 10, width: 80, height: 30),
            screenSize: CGSize(width: 1920, height: 1080), imageSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(rect, CGRect(x: 20, y: 1040, width: 80, height: 30))
    }
    func testOutOfBoundsSelectionIsEmpty() {
        XCTAssertEqual(SelectionGeometry.pixelRect(selection: CGRect(x: 200, y: 200, width: 10, height: 10),
            screenSize: CGSize(width: 100, height: 100), imageSize: CGSize(width: 200, height: 200)), .zero)
    }
    func testActualVisionRecognition() async throws {
        let image = try fixture(text: "FastOCR 12345\n你好世界")
        let result = try await VisionOCREngine().recognize(image: image)
        XCTAssertTrue(result.text.contains("FastOCR"), result.text)
        XCTAssertTrue(result.text.contains("12345"), result.text)
        XCTAssertTrue(result.text.contains("你好世界"), result.text)
        XCTAssertFalse(result.blocks.isEmpty)
        XCTAssertTrue(result.blocks.allSatisfy { $0.confidence > 0 && !$0.boundingBox.isEmpty })
    }
    func testBlankImageReturnsNoText() async throws {
        let result = try await VisionOCREngine().recognize(image: fixture(text: ""))
        XCTAssertTrue(result.text.isEmpty)
    }
    private func fixture(text: String) throws -> CGImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 300).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 80), withAttributes: [
            .font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.cgImage)
    }
}
