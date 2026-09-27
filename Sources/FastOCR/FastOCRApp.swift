import AppKit
import SwiftUI
import OCRCore
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let hotkey = GlobalHotkey()
    private let capture = CaptureCoordinator()
    private let permission = ScreenRecordingPermissionService()
    private var permissionUIActive = false
    private var permissionItem: NSMenuItem!
    private let engine: any OCREngine = VisionOCREngine()
    private var busy = false
    private var preparing = false
    private var captureTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.chenchao.FastOCR", category: "performance")
    private var latest: OCRResult?
    private var resultWindow: NSWindow?
    private var hud: NSPanel?
    private var hudTask: Task<Void, Never>?
    private var captureScreen: NSScreen?
    private var previousApp: NSRunningApplication?
    private var captureItem: NSMenuItem!
    private var resultItem: NSMenuItem!
    private var screenObserver: NSObjectProtocol?
    private let subtitles = SubtitleController()
    private var subtitlePauseItem: NSMenuItem!
    private var subtitleStopItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "FastOCR 实时翻译")
        status.button?.toolTip = "FastOCR · 应用音频与字幕实时翻译 · ⌘⇧O 截图取字"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "FastOCR · 实时翻译助手", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("实时翻译…", #selector(showSubtitleSettings)))
        subtitlePauseItem = item("暂停翻译", #selector(toggleSubtitlePause))
        subtitleStopItem = item("结束翻译", #selector(stopSubtitles))
        menu.addItem(subtitlePauseItem)
        menu.addItem(subtitleStopItem)
        subtitles.onSelect = { [weak self] in self?.selectSubtitleRegion() }
        subtitles.onStartAudio = { [weak self] in self?.startApplicationAudio() }
        subtitles.onStateChange = { [weak self] in self?.updateSubtitleMenu() }
        updateSubtitleMenu()
        menu.addItem(.separator())
        captureItem = item("框选识别", #selector(startCapture), key: "o")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(captureItem)
        resultItem = item("查看上次结果…", #selector(showResult))
        resultItem.isEnabled = false
        menu.addItem(resultItem)
        let copy = item("识别后自动复制", #selector(toggleCopy))
        copy.state = autoCopy ? .on : .off
        menu.addItem(copy)
        menu.addItem(.separator())
        permissionItem = item("屏幕录制权限…", #selector(showPermissions))
        menu.addItem(permissionItem)
        menu.addItem(item("在 Finder 中定位当前应用", #selector(revealApplication)))
        menu.addItem(item("关于 FastOCR", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("退出 FastOCR", #selector(quit), key: "q"))
        status.menu = menu
        refreshPermission()
        hotkey.onPress = { [weak self] in self?.startCapture() }
        if !hotkey.register() {
            showAlert("快捷键注册失败", "⌘⇧O 可能已被其他应用占用。你仍可通过菜单栏的「框选识别」使用 FastOCR。")
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.captureTask?.cancel(); self?.capture.cancel()
                    self?.subtitles.screenConfigurationChanged()
                }
            }
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            subtitles.showSettings()
        }
    }
    private var autoCopy: Bool {
        UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true
    }
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    @objc private func toggleCopy(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!autoCopy, forKey: "autoCopy")
        sender.state = autoCopy ? .on : .off
    }
    @objc private func startCapture() {
        guard !busy else {
            logger.info("trigger_ignored_busy")
            if preparing { status.button?.title = " 准备中…" }
            return
        }
        let triggerTime = ProcessInfo.processInfo.systemUptime
        guard !permissionUIActive, !permission.requesting else { return }
        if !permission.refresh() {
            permissionUIActive = true
            defer { permissionUIActive = false; refreshPermission() }
            if !permission.requestedThisSession, permission.request() {
                // This user-triggered request is now allowed to continue to capture.
            } else {
                presentPermissionGuidance()
                return
            }
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        if subtitles.isActive && !subtitles.isPaused { subtitles.pause() }
        setBusy(true)
        preparing = true
        status.button?.title = " 准备中…"
        hudTask?.cancel()
        hud?.orderOut(nil)
        resultWindow?.orderOut(nil)
        captureTask = Task {
            do {
                // Allow the menu action to finish; no fixed delay for hotkeys.
                await Task.yield()
                let snapshots = try await capture.prepare()
                try Task.checkCancellation()
                preparing = false
                status.button?.title = ""
                logger.info("selection_ready_ms=\((ProcessInfo.processInfo.systemUptime - triggerTime) * 1000)")
                capture.select(snapshots) { [weak self] outcome in
                    guard let self else { return }
                    self.captureScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                    self.previousApp?.activate(options: [])
                    switch outcome {
                    case .success(let image):
                        guard let image else { self.setBusy(false); return }
                        self.recognize(image)
                    case .failure(let error):
                        self.setBusy(false)
                        self.logger.error("crop_failed")
                        self.showAlert("无法识别选区", error.localizedDescription)
                    }
                }
            } catch is CancellationError {
                setBusy(false)
            } catch {
                setBusy(false)
                logger.error("capture_failed")
                refreshPermission()
                if permission.status == .unavailable {
                    showPermissions()
                } else {
                    showAlert("截图失败", error.localizedDescription + "\n权限检查已通过，但本次捕获未成功。请重试；若刚修改授权后持续失败，可先复制需保留的结果，再退出并重新打开 FastOCR。")
                }
            }
        }
    }
    private func recognize(_ image: CGImage) {
        let shouldCopy = autoCopy
        showHUD("正在识别，请稍候粘贴…", symbol: "text.viewfinder", seconds: nil)
        Task {
            do {
                let result = try await engine.recognize(image: image)
                defer { setBusy(false) }
                logger.info("ocr_ms=\(result.duration * 1000) blocks=\(result.blocks.count)")
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    showHUD("未发现文字，请重新框选", symbol: "text.magnifyingglass")
                    return
                }
                latest = result
                resultItem.isEnabled = true
                if shouldCopy {
                    if copyText(result.text) {
                        showHUD("已复制 \(result.text.count) 个字符", symbol: "checkmark.circle.fill", preview: result.text)
                    } else {
                        showHUD("复制失败，可在此处复制", symbol: "exclamationmark.triangle", preview: result.text)
                        showResult()
                    }
                } else {
                    showHUD("识别完成 · \(result.text.count) 个字符", symbol: "checkmark.circle.fill", preview: result.text)
                    showResult()
                }
            } catch {
                setBusy(false)
                hud?.orderOut(nil)
                showAlert("文字识别失败", error.localizedDescription)
            }
        }
    }
    private func setBusy(_ value: Bool) {
        busy = value
        if !value { preparing = false }
        status.button?.title = value ? " 识别中…" : ""
        captureItem.isEnabled = !value
        captureItem.title = value ? "正在处理…" : "框选识别"
        status.button?.appearsDisabled = value
        updateSubtitleMenu()
    }
    @objc private func showSubtitleSettings() { subtitles.showSettings() }
    @objc private func toggleSubtitlePause() { subtitles.togglePause() }
    @objc private func stopSubtitles() { subtitles.stop() }
    private func updateSubtitleMenu() {
        subtitlePauseItem?.isEnabled = subtitles.isActive && !busy
        subtitleStopItem?.isEnabled = subtitles.isActive && !busy
        subtitlePauseItem?.title = subtitles.isPaused ? "继续翻译" : "暂停翻译"
        if !busy { status.button?.title = subtitles.isActive ? (subtitles.isPaused ? " 暂停" : " 译") : "" }
    }
    private func startApplicationAudio() {
        guard !busy, !permissionUIActive, !permission.requesting else { return }
        subtitles.refreshModels()
        do { try subtitles.validateAudio() }
        catch { subtitles.report(error.localizedDescription); subtitles.showSettings(); return }
        // ScreenCaptureKit system audio shares the screen-capture authorization on macOS 14.
        if !permission.refresh() {
            permissionUIActive = true
            defer { permissionUIActive = false; refreshPermission() }
            if !permission.requestedThisSession, permission.request() { }
            else { presentPermissionGuidance(); return }
        }
        subtitles.startAudio()
    }
    private func selectSubtitleRegion() {
        guard !busy, !permissionUIActive, !permission.requesting else { return }
        subtitles.refreshModels()
        do { try subtitles.validate() }
        catch { subtitles.report(error.localizedDescription); subtitles.showSettings(); return }
        if !permission.refresh() {
            permissionUIActive = true
            defer { permissionUIActive = false; refreshPermission() }
            if !permission.requestedThisSession, permission.request() { }
            else { presentPermissionGuidance(); return }
        }
        let resumeOnCancel = subtitles.isActive && !subtitles.isPaused
        subtitles.pause()
        subtitles.hideSettings()
        hudTask?.cancel(); hud?.orderOut(nil); resultWindow?.orderOut(nil)
        previousApp = NSWorkspace.shared.frontmostApplication
        setBusy(true)
        preparing = true
        status.button?.title = " 准备中…"
        captureTask = Task {
            do {
                await Task.yield()
                let snapshots = try await capture.prepare()
                try Task.checkCancellation()
                preparing = false
                capture.selectRegion(snapshots) { [weak self] result in
                    guard let self else { return }
                    self.setBusy(false)
                    self.previousApp?.activate(options: [])
                    switch result {
                    case .success(let selection):
                        if let selection { self.subtitles.start(selection) }
                        else if resumeOnCancel { self.subtitles.togglePause() }
                    case .failure(let error):
                        self.subtitles.report(error.localizedDescription)
                        self.subtitles.showSettings()
                    }
                }
            } catch is CancellationError { setBusy(false) }
            catch {
                setBusy(false)
                subtitles.report(error.localizedDescription)
                subtitles.showSettings()
            }
        }
    }
    @discardableResult private func copyText(_ text: String) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        let success = ClipboardService.copy(text)
        logger.info("clipboard_success=\(success) clipboard_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        return success
    }
    @objc private func showResult() {
        guard let latest else { return }
        if resultWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "FastOCR · 识别结果"
            window.minSize = NSSize(width: 420, height: 280)
            window.isReleasedWhenClosed = false
            window.center()
            resultWindow = window
        }
        resultWindow?.contentView = NSHostingView(rootView: ResultView(result: latest, copy: { [weak self] in self?.copyText($0) ?? false }).id(UUID()))
        NSApp.activate(ignoringOtherApps: true)
        resultWindow?.makeKeyAndOrderFront(nil)
    }
    private func showHUD(_ text: String, symbol: String, preview: String? = nil, seconds: Double? = 2) {
        hudTask?.cancel()
        hud?.orderOut(nil)
        let width: CGFloat = preview == nil ? 330 : 380
        let height: CGFloat = preview == nil ? 72 : 210
        let panel = ResultHUDPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = preview == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = captureScreen ?? NSScreen.main
        let expandedHeight = min(max(300, (screen?.visibleFrame.height ?? 700) - 48), 560)
        panel.contentView = NSHostingView(rootView: ResultHUDView(title: text, symbol: symbol, preview: preview,
            expandedHeight: expandedHeight, copy: { [weak self] in self?.copyText($0) ?? false },
            resize: { [weak panel] expanded in
                guard let panel else { return }
                if expanded { self.hudTask?.cancel() }
                let newHeight = expanded ? expandedHeight : height
                let newWidth: CGFloat = expanded ? 520 : width
                let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
                let x = min(max(panel.frame.maxX - newWidth, visible.minX), visible.maxX - newWidth)
                let y = min(max(panel.frame.minY, visible.minY), visible.maxY - newHeight)
                panel.setFrame(NSRect(x: x, y: y, width: newWidth, height: newHeight),
                               display: true, animate: true)
            }, drag: { [weak panel] in
                guard let panel else { return }
                if panel.dragWithMouse() { self.hudTask?.cancel() }
            }, endDrag: { [weak panel] in panel?.endDrag() },
            close: { [weak panel] in panel?.orderOut(nil) }))
        if let screen {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - width - 24, y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        hud = panel
        if let seconds = preview == nil ? seconds : 6 {
            hudTask = Task { [weak panel] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
                panel?.orderOut(nil)
            }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from Settings updates status only; never starts capture.
        guard permissionItem != nil else { return }
        refreshPermission()
    }
    private func refreshPermission() {
        let ready = permission.refresh()
        permissionItem?.title = ready ? "屏幕录制：已授权…" : "屏幕录制：尚未获得权限…"
    }
    @objc private func showPermissions() {
        guard !permissionUIActive, !permission.requesting else { return }
        permissionUIActive = true
        defer { permissionUIActive = false; refreshPermission() }
        refreshPermission()
        presentPermissionGuidance()
    }
    private func presentPermissionGuidance() {
        let ready = permission.refresh()
        let alert = NSAlert()
        alert.messageText = ready ? "屏幕录制权限已授权" : "尚未获得屏幕录制权限"
        alert.informativeText = ready
            ? "可以从实时翻译中选择应用开始监听，也可按 ⌘⇧O 框选取字。若刚授权后仍无法使用，可先保留需要的结果，再退出并重新打开 FastOCR。"
            : "FastOCR 仅在你点击开始后捕获所选应用的播放声音，或读取你框选的屏幕字幕。不启用麦克风，不保存录音或截图。语音和文字识别在本机完成；选择百度翻译时只发送识别文字。\n\n请在系统设置 → 隐私与安全性 → 屏幕录制（部分版本称「屏幕与系统音频录制」）中允许当前 FastOCR。系统可能仍在等待你的选择；此状态不代表你曾拒绝。\n\n返回后会重新检查，需要再次点击开始。若授权后仍无法使用，可手动重启应用。"
        if !ready && !permission.requestedThisSession {
            alert.addButton(withTitle: "申请访问")
        } else {
            alert.addButton(withTitle: "打开系统设置")
        }
        alert.addButton(withTitle: "完成")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if !ready && !permission.requestedThisSession {
                if permission.request() {
                    showAlert("权限已就绪", "请再次点击开始监听，或按 ⌘⇧O 框选识别。")
                } else {
                    // Keep the system prompt independent; do not automatically navigate away.
                    let help = NSAlert()
                    help.messageText = "请完成系统授权"
                    help.informativeText = "若系统没有显示提示或权限仍未开启，可打开系统设置手动允许 FastOCR。"
                    help.addButton(withTitle: "打开系统设置")
                    help.addButton(withTitle: "稍后")
                    if help.runModal() == .alertFirstButtonReturn { openPermissions() }
                }
            } else { openPermissions() }
        }
    }
    @objc private func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    private func openPermissions() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
              NSWorkspace.shared.open(url) else {
            showAlert("请手动打开系统设置", "系统设置 → 隐私与安全性 → 屏幕录制。可从菜单栏选择「在 Finder 中定位当前应用」，确认授权的是当前使用的 FastOCR。")
            return
        }
    }
    @objc private func showAbout() {
        showAlert("FastOCR " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"), "应用语音与屏幕字幕，实时翻译。\n\n选择一个应用监听播放声音，或框选字幕区域。支持中、英、日语及简繁中文输出。语音识别在本机完成；可选离线或百度机器翻译。\n\n⌘⇧O：框选取字；Esc：取消。\n不启用麦克风，不保存录音。")
    }
    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) { subtitles.stop() }
    @objc private func quit() { NSApp.terminate(nil) }
}
struct ResultView: View {
    let result: OCRResult
    let copy: (String) -> Bool
    @State private var copyFailed = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "text.viewfinder").font(.title).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("识别结果").font(.title2.bold())
                    Text("\(result.text.count) 个字符 · \(result.blocks.count) 个文本块 · \(String(format: "%.2f", result.duration)) 秒")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "已复制" : "复制全文") {
                    copied = copy(result.text)
                    copyFailed = !copied
                }.buttonStyle(.borderedProminent)
            }
            ScrollView {
                Text(result.text).font(.system(size: 15)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Text("内容仅保留在本次运行中 · ⌘⇧O 继续识别").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 380, minHeight: 240)
        .alert("复制失败", isPresented: $copyFailed) {
            Button("好", role: .cancel) {}
        } message: { Text("剪贴板写入或校验失败，请重试复制。识别结果仍保留在窗口中。") }
    }
}

private final class ResultHUDPanel: NSPanel {
    private var dragOrigin: NSPoint?
    private var dragMouseOrigin: NSPoint?
    override var canBecomeKey: Bool { true }

    func dragWithMouse() -> Bool {
        let mouse = NSEvent.mouseLocation
        if dragOrigin == nil {
            dragOrigin = frame.origin
            dragMouseOrigin = mouse
            return false
        }
        guard let origin = dragOrigin, let start = dragMouseOrigin else { return false }
        let dx = mouse.x - start.x
        let dy = mouse.y - start.y
        setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        return abs(dx) + abs(dy) > 3
    }

    func endDrag() {
        dragOrigin = nil
        dragMouseOrigin = nil
    }
}

private struct ResultHUDView: View {
    let title: String
    let symbol: String
    let preview: String?
    let expandedHeight: CGFloat
    let copy: (String) -> Bool
    let resize: (Bool) -> Void
    let drag: () -> Void
    let endDrag: () -> Void
    let close: () -> Void
    @State private var expanded = false
    @State private var copied = false
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.blue)
                    Text(title).font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { _ in drag() }
                    .onEnded { _ in endDrag() })
                if preview != nil {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭提示")
                }
            }
            if let preview {
                Divider()
                ScrollView {
                    Text(expanded ? preview : String(preview.prefix(600)))
                        .font(.system(size: 13)).lineSpacing(3)
                        .lineLimit(expanded ? nil : 4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Button(expanded ? "收起" : "展开全文") {
                        expanded.toggle()
                        resize(expanded)
                    }
                    Button(copied ? "已复制" : "复制全文") {
                        copied = copy(preview)
                        copyFailed = !copied
                    }
                    Spacer()
                    Text("可选中文字复制").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(width: expanded ? 520 : (preview == nil ? 330 : 380),
               height: expanded ? expandedHeight : (preview == nil ? 72 : 210), alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .alert("复制失败", isPresented: $copyFailed) {
            Button("好", role: .cancel) {}
        } message: { Text("剪贴板写入失败，请选中文字后按 ⌘C，或打开完整结果窗口重试。") }
    }
}
@main
struct FastOCRApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
