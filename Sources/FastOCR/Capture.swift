import AppKit
import ScreenCaptureKit
import OCRCore
import OSLog

struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
}
enum CaptureError: LocalizedError {
    case noDisplays, cropFailed
    var errorDescription: String? {
        switch self {
        case .noDisplays: return "没有找到匹配的可捕获显示器，请确认显示器连接后重试。"
        case .cropFailed: return "选区太小或已超出屏幕，请重新框选。"
        }
    }
}
@MainActor
final class CaptureCoordinator {
    private var panels: [SelectionPanel] = []
    private var monitor: Any?
    private var completion: ((Result<CGImage?, Error>) -> Void)?
    private let logger = Logger(subsystem: "com.chenchao.FastOCR", category: "performance")
    func prepare() async throws -> [ScreenSnapshot] {
        let began = ProcessInfo.processInfo.systemUptime
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        logger.info("enumeration_ms=\((ProcessInfo.processInfo.systemUptime - began) * 1000)")
        let screens = NSScreen.screens
        // Exclude our own windows so feedback and closing menus cannot enter the image.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, screen) in screens.enumerated() {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                    throw CaptureError.noDisplays
                }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let config = SCStreamConfiguration()
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor)
                config.showsCursor = false
                group.addTask {
                    let start = ProcessInfo.processInfo.systemUptime
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    Logger(subsystem: "com.chenchao.FastOCR", category: "performance")
                        .info("display_index=\(index) capture_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
                    return (index, image)
                }
            }
            var images: [(Int, CGImage)] = []
            for try await image in group { images.append(image) }
            return images.sorted { $0.0 < $1.0 }
        }
        guard !images.isEmpty else { throw CaptureError.noDisplays }
        return images.map { ScreenSnapshot(screen: screens[$0.0], image: $0.1) }
    }
    func select(_ snapshots: [ScreenSnapshot], completion: @escaping (Result<CGImage?, Error>) -> Void) {
        self.completion = completion
        for snapshot in snapshots {
            let panel = SelectionPanel(contentRect: snapshot.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: snapshot.screen.frame.size), snapshot: snapshot)
            view.onFinish = { [weak self] rect in
                guard let self else { return }
                let pixelRect = SelectionGeometry.pixelRect(selection: rect, screenSize: snapshot.screen.frame.size,
                    imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
                guard !pixelRect.isEmpty, let image = snapshot.image.cropping(to: pixelRect) else {
                    self.finish(.failure(CaptureError.cropFailed))
                    return
                }
                self.finish(.success(image))
            }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let active = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
        active?.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(.success(nil)) }
            return nil
        }
    }
    func cancel() { finish(.success(nil)) }
    private func finish(_ image: Result<CGImage?, Error>) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        let callback = completion
        completion = nil
        callback?(image)
    }
}
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
final class SelectionView: NSView {
    let snapshot: ScreenSnapshot
    var onFinish: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero
    private var tracking: NSTrackingArea?
    init(frame: CGRect, snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        // Transfer keyboard/cursor ownership before the first click on another display.
        if NSEvent.pressedMouseButtons == 0 { window?.makeKey() }
        NSCursor.crosshair.set()
    }
    override func mouseMoved(with event: NSEvent) {
        if NSEvent.pressedMouseButtons == 0, window?.isKeyWindow == false { window?.makeKey() }
        NSCursor.crosshair.set()
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(snapshot.image, in: bounds)
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()
        if !selection.isEmpty {
            context.saveGState()
            context.clip(to: selection)
            context.draw(snapshot.image, in: bounds)
            context.restoreGState()
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()
        }
        let message = selection.isEmpty ? "拖动框选文字 · Esc 取消" : "\(Int(selection.width)) × \(Int(selection.height)) · 松开识别"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = (message as NSString).size(withAttributes: attrs)
        let box = CGRect(x: (bounds.width - size.width) / 2 - 18, y: bounds.height - 94, width: size.width + 36, height: 44)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (message as NSString).draw(at: CGPoint(x: box.minX + 18, y: box.minY + 13), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        start = nil
        if selection.width >= 4 && selection.height >= 4 { onFinish?(selection) }
        else { selection = .zero; needsDisplay = true }
    }
}
