import XCTest
@testable import OCRCore

final class PermissionTests: XCTestCase {
    @MainActor func testRefreshNeverRequestsAndDetectsRevocation() {
        var allowed = true
        var requests = 0
        let service = ScreenRecordingPermissionService(check: { allowed }, request: { requests += 1; return true })
        XCTAssertEqual(service.status, .unknown)
        XCTAssertTrue(service.refresh())
        allowed = false
        XCTAssertFalse(service.refresh())
        XCTAssertEqual(service.status, .unavailable)
        XCTAssertEqual(requests, 0)
    }
    @MainActor func testAlreadyAuthorizedDoesNotRequest() {
        var requests = 0
        let service = ScreenRecordingPermissionService(check: { true }, request: { requests += 1; return true })
        XCTAssertTrue(service.request())
        XCTAssertEqual(requests, 0)
    }
    @MainActor func testGrantRechecksCurrentState() {
        var allowed = false
        let service = ScreenRecordingPermissionService(check: { allowed }, request: { allowed = true; return false })
        XCTAssertTrue(service.request())
        XCTAssertTrue(service.requestedThisSession)
        XCTAssertFalse(service.requesting)
    }
    @MainActor func testRequestReturnDoesNotOverrideFailedPreflight() {
        let service = ScreenRecordingPermissionService(check: { false }, request: { true })
        XCTAssertFalse(service.request())
        XCTAssertEqual(service.status, .unavailable)
    }
    @MainActor func testReentrantRequestIsIgnored() {
        var requests = 0
        var service: ScreenRecordingPermissionService!
        service = ScreenRecordingPermissionService(check: { false }, request: {
            requests += 1
            XCTAssertFalse(service.request())
            return false
        })
        XCTAssertFalse(service.request())
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(service.requesting)
    }
}
