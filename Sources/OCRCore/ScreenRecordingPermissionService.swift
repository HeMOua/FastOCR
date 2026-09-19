import CoreGraphics

/// A false preflight result does not distinguish first use from a prior refusal.
@MainActor
public final class ScreenRecordingPermissionService {
    public enum Status: Equatable { case unknown, unavailable, authorized }
    public private(set) var status: Status = .unknown
    public private(set) var requesting = false
    public private(set) var requestedThisSession = false
    private let checkAccess: () -> Bool
    private let requestAccess: () -> Bool

    public init(check: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
                request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        checkAccess = check
        requestAccess = request
    }
    @discardableResult public func refresh() -> Bool {
        let ready = checkAccess()
        status = ready ? .authorized : .unavailable
        return ready
    }
    /// Only call from a user action. Refresh and app activation never request access.
    @discardableResult public func request() -> Bool {
        guard !requesting else { return false }
        if refresh() { return true }
        requesting = true
        requestedThisSession = true
        defer { requesting = false }
        _ = requestAccess()
        // The request return alone is not treated as proof of current capability.
        return refresh()
    }
}
