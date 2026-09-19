import AppKit
import XCTest
@testable import OCRCore

final class ClipboardTests: XCTestCase {
    @MainActor func testUnicodeAndMultilineRoundTrip() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let text = "中文 OCR\n  swift build\n🙂 123"
        XCTAssertTrue(ClipboardService.copy(text, to: board))
        XCTAssertEqual(board.string(forType: .string), text)
    }
    @MainActor func testBlankDoesNotEraseExistingContent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous", forType: .string)
        XCTAssertFalse(ClipboardService.copy(" \n\t", to: board))
        XCTAssertEqual(board.string(forType: .string), "previous")
    }
    @MainActor func testNewResultReplacesPreviousResult() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(ClipboardService.copy("first", to: board))
        XCTAssertTrue(ClipboardService.copy("second", to: board))
        XCTAssertEqual(board.string(forType: .string), "second")
    }
}
