import AppKit
import SwiftUI
import OCRCore

@MainActor
final class SubtitleController: ObservableObject {
    @Published var settings = SubtitleSettings.load() {
        didSet { settings.save(); overlay?.ignoresMouseEvents = settings.clickThrough }
    }
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var original = ""
    @Published private(set) var translated = ""
    @Published private(set) var status = "选择声音来源或字幕区域，开始实时翻译"
    @Published private(set) var hasError = false
    @Published private(set) var modelsReady = OfflineTranslationEngine.isInstalled()
    @Published private(set) var installing = false
    @Published private(set) var translationHint = ""
    @Published private(set) var applications: [AudioApplication] = []
    @Published var selectedApplicationID: Int32 = 0 {
        didSet { if let app = selectedApplication { settings.audioApplicationBundleID = app.bundleID } }
    }
    @Published private(set) var speechModelsReady = LocalSpeechRecognizer.isInstalled()
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var speechStatus = "未开始监听"
    @Published private(set) var audioWarning = ""
    @Published private(set) var listeningName = ""
    @Published private(set) var speechMilliseconds = 0
    var onSelect: (() -> Void)?
    var onStartAudio: (() -> Void)?
    var onStateChange: (() -> Void)?
    private var settingsWindow: NSWindow?
    private var overlay: NSPanel?
    private var region: CaptureSelection?
    private var capture: SubtitleCapture?
    private var captureTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private let translationScheduler = LatestTranslationScheduler()
    private var latestFrame: CGImage?
    private var tracker = SubtitleTracker()
    private var subtitleVersion = 0
    private var listeningApplication: AudioApplication?
    private var audioCapture: ApplicationAudioCapture?
    private var speechRecognizer: LocalSpeechRecognizer?
    private var audioMonitorTask: Task<Void, Never>?
    private var lastSoundAt: TimeInterval = 0
    private var lastCaptionAt: TimeInterval = 0
    private var recognizingSpeech = false
    private var generation = UUID()
    private var engine: (any SubtitleTranslationEngine)?
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []

    var selectedApplication: AudioApplication? { applications.first { $0.id == selectedApplicationID } }
    var isAudioSession: Bool { listeningApplication != nil }
    var canStart: Bool {
        !installing && (settings.online || modelsReady) &&
            (settings.inputMode == .screenRegion || (speechModelsReady && selectedApplication != nil))
    }
    func refreshApplications() {
        applications = AudioApplication.running()
        if !applications.contains(where: { $0.id == selectedApplicationID }) {
            selectedApplicationID = applications.first(where: { $0.bundleID == settings.audioApplicationBundleID })?.id ?? 0
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "FastOCR · 实时翻译"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SubtitleSettingsView(controller: self))
            window.center()
            settingsWindow = window
        }
        refreshModels()
        refreshApplications()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func hideSettings() { settingsWindow?.orderOut(nil) }
    func refreshModels() { modelsReady = OfflineTranslationEngine.isInstalled(); speechModelsReady = LocalSpeechRecognizer.isInstalled() }
    private var resources: URL? { Bundle.main.resourceURL?.appendingPathComponent("Offline") }
    private var speechExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FastOCRSpeech") }
    func validateAudio() throws {
        try validate()
        guard selectedApplication != nil else { throw TranslationFailure("请先选择一个正在运行的应用。") }
        guard speechModelsReady else { throw TranslationFailure("请先准备本地语音模型。") }
        guard FileManager.default.isExecutableFile(atPath: speechExecutable.path) else {
            throw TranslationFailure("找不到语音组件，请使用包含语音组件的 FastOCR.app。")
        }
    }
    func startAudio() {
        do { try validateAudio() } catch { report(error.localizedDescription); showSettings(); return }
        guard let application = selectedApplication, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        stop()
        listeningApplication = application
        listeningName = application.name
        isActive = true
        configureTranslationEngine()
        speechRecognizer = LocalSpeechRecognizer(executable: speechExecutable)
        showOverlay(screen: screen, rect: CGRect(x: screen.frame.width / 2 - 320, y: 20, width: 640, height: 0))
        hideSettings()
        runAudio(application)
    }
    private func runAudio(_ application: AudioApplication) {
        generation = UUID()
        let token = generation
        hasError = false; audioWarning = ""; audioLevel = 0; speechMilliseconds = 0
        status = "正在准备应用音频翻译"
        speechStatus = "正在加载语音模型，尚未开始监听…"
        lastSoundAt = ProcessInfo.processInfo.systemUptime
        lastCaptionAt = lastSoundAt
        recognizingSpeech = false
        let source = settings.source, target = settings.target
        let maxAge = max(8, settings.audioSegmentSeconds * 2.5)
        guard let recognizer = speechRecognizer else { fail(TranslationFailure("语音识别器未就绪。")); return }
        let capture = ApplicationAudioCapture(threshold: Float(settings.audioThreshold), maximumSeconds: settings.audioSegmentSeconds) { [weak self] activity in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch activity {
                case .level(let rms):
                    self.audioLevel = min(1, Double(sqrt(rms)) * 3)
                    if Double(rms) >= self.settings.audioThreshold {
                        self.lastSoundAt = ProcessInfo.processInfo.systemUptime
                        if !self.recognizingSpeech { self.speechStatus = "正在聆听 \(application.name)…" }
                    }
                case .dropped(let count): self.audioWarning = "识别暂时跟不上，已跳过 \(count) 段较早音频。"
                }
            }
        }
        audioCapture = capture
        captureTask = Task {
            do {
                try await recognizer.prepare()
                try Task.checkCancellation()
                guard generation == token else { return }
                try await capture.start(application: application)
                try Task.checkCancellation()
                guard generation == token else { await capture.stop(); return }
                speechStatus = "等待 \(application.name) 播放声音…"
                status = "正在监听 \(application.name)"
                startAudioMonitor(application, token: token)
                for try await segment in capture.segments {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    guard ProcessInfo.processInfo.systemUptime - segment.endedAt <= maxAge else {
                        audioWarning = "识别暂时跟不上，已跳过过期音频。"; continue
                    }
                    recognizingSpeech = true
                    speechStatus = "正在识别语音…"
                    let began = ProcessInfo.processInfo.systemUptime
                    do {
                        let result = try await recognizer.recognize(segment, language: source)
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        recognizingSpeech = false
                        speechMilliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                        speechStatus = "正在聆听 \(application.name)…"
                        guard ProcessInfo.processInfo.systemUptime - segment.endedAt <= maxAge else {
                            audioWarning = "本段识别耗时过长，已跳过，继续监听。"; continue
                        }
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        guard ["zh", "en", "ja"].contains(result.language) else {
                            audioWarning = "未识别为中、英、日语音，建议手动指定来源语言。"; continue
                        }
                        original = source.normalizeChinese(text)
                        translated = ""
                        subtitleVersion += 1
                        lastCaptionAt = ProcessInfo.processInfo.systemUptime
                        translate(original, version: subtitleVersion, source: source == .automatic ? result.subtitleLanguage : source, target: target, token: token)
                    } catch {
                        guard generation == token, !Task.isCancelled else { return }
                        recognizingSpeech = false
                        audioWarning = error.localizedDescription + " 继续监听下一段。"
                        speechStatus = "等待下一段语音…"
                    }
                }
            } catch is CancellationError {
                if generation == token, !Task.isCancelled { fail(TranslationFailure("语音模型准备超时，请点击继续重试。")) }
            }
            catch { if generation == token { fail(error) } }
        }
        onStateChange?()
    }
    private func startAudioMonitor(_ application: AudioApplication, token: UUID) {
        audioMonitorTask = Task {
            while !Task.isCancelled, generation == token {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard generation == token else { return }
                guard let app = NSRunningApplication(processIdentifier: application.id), !app.isTerminated,
                      app.bundleIdentifier == application.bundleID else {
                    fail(TranslationFailure("\(application.name) 已退出，已暂停监听。请结束本次翻译，重新打开应用后刷新列表并开始。")); return
                }
                let now = ProcessInfo.processInfo.systemUptime
                if !recognizingSpeech, now - lastSoundAt > 2 { speechStatus = "未检测到声音，请在 \(application.name) 中播放内容。" }
                if !recognizingSpeech, now - lastSoundAt > 5, now - lastCaptionAt > 5 {
                    original = ""; translated = ""; translationHint = ""
                    subtitleVersion += 1
                    translationScheduler.cancel()
                }
            }
        }
    }
    func validate() throws {
        if settings.online {
            guard !settings.baiduAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !SubtitleKeychain.read(appID: settings.baiduAppID).isEmpty else {
                throw TranslationFailure("请填写百度翻译 APP ID，并保存对应的密钥。")
            }
        } else {
            guard modelsReady else { throw TranslationFailure("请先准备离线模型。") }
            guard let resources, FileManager.default.fileExists(atPath: resources.appendingPathComponent("translate_worker.py").path) else {
                throw TranslationFailure("找不到离线翻译组件，请运行打包后的 FastOCR.app。")
            }
        }
    }
    func report(_ message: String) { status = message; hasError = true; onStateChange?() }
    func start(_ region: CaptureSelection) {
        stop()
        do { try validate() } catch { report(error.localizedDescription); showSettings(); return }
        self.region = region
        isActive = true
        isPaused = false
        cache.removeAll(); cacheOrder.removeAll()
        configureTranslationEngine()
        showOverlay(screen: region.screen, rect: region.rect)
        runCapture(region)
    }
    private func configureTranslationEngine() {
        if settings.online {
            // The scheduler applies the live per-caption deadline; transport has a hard upper bound.
            engine = BaiduTranslationEngine(appID: settings.baiduAppID, secret: SubtitleKeychain.read(appID: settings.baiduAppID), timeout: 10)
        } else if let resources {
            engine = OfflineTranslationEngine(script: resources.appendingPathComponent("translate_worker.py"))
        }
    }
    private func runCapture(_ region: CaptureSelection) {
        generation = UUID()
        let token = generation
        tracker = SubtitleTracker()
        latestFrame = nil
        hasError = false
        translationHint = ""
        status = "正在连接字幕区域…"
        let source = settings.source
        let target = settings.target
        let capture = SubtitleCapture()
        self.capture = capture
        captureTask = Task {
            do {
                try await capture.start(region)
                guard generation == token else { await capture.stop(); return }
                status = settings.online ? "在线翻译中" : "本地离线翻译中"
                onStateChange?()
                for try await image in capture.frames {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    latestFrame = image
                }
            } catch is CancellationError { }
            catch { if generation == token { fail(error) } }
        }
        ocrTask = Task {
            let ocr = VisionOCREngine(languages: source.recognitionLanguages)
            do {
                while !Task.isCancelled, generation == token {
                    if let frame = latestFrame {
                        let result = try await ocr.recognize(image: frame)
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        let text = result.blocks.filter { $0.confidence >= 0.25 }.map(\.text).joined(separator: "\n")
                        let update = tracker.observe(text, at: ProcessInfo.processInfo.systemUptime)
                        subtitleVersion = update.version
                        if update.clear {
                            original = ""; translated = ""; translationHint = ""
                            translationScheduler.cancel()
                        }
                        if let text = update.text {
                            original = text
                            translated = ""
                            translate(text, version: update.version, source: source, target: target, token: token)
                        }
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch is CancellationError { }
            catch { if generation == token { fail(error) } }
        }
        onStateChange?()
    }
    private func translate(_ text: String, version: Int, source: SubtitleLanguage, target: SubtitleLanguage, token: UUID) {
        guard let engine else { return }
        translationScheduler.cancel()
        translationHint = "正在翻译…"
        status = settings.online ? "百度机器翻译中" : "本地离线翻译中"
        let input = TranslationInput(text: text, source: source, target: target)
        let key = input.source.rawValue + ":" + target.rawValue + ":" + SubtitleTracker.key(text)
        if let cached = cache[key] { translated = cached; translationHint = ""; return }
        translationScheduler.submit(input, engine: engine, timeout: settings.translationTimeout,
                                    minimumInterval: settings.online ? settings.requestInterval : 0) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success(let value):
                if self.cache[key] == nil { self.cacheOrder.append(key) }
                self.cache[key] = value
                if self.cacheOrder.count > 100 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
                if self.subtitleVersion == version { self.translated = value; self.translationHint = "" }
            case .failure(let error):
                guard self.subtitleVersion == version else { return }
                self.translationHint = "本句已跳过 · 继续识别"
                self.status = error.localizedDescription
            }
        }
    }
    private func fail(_ error: Error) {
        pause()
        report(error is CancellationError ? "翻译超时，已暂停。可点击继续重试。" : error.localizedDescription)
    }
    func togglePause() {
        guard isActive else { return }
        if isPaused {
            isPaused = false
            if let application = listeningApplication { runAudio(application) }
            else if let region { runCapture(region) }
            else { stop() }
        } else { pause() }
    }
    func pause() {
        guard isActive else { return }
        cancelWork()
        isPaused = true
        status = "已暂停"
        onStateChange?()
    }
    private func cancelWork() {
        generation = UUID()
        captureTask?.cancel(); captureTask = nil
        ocrTask?.cancel(); ocrTask = nil
        audioMonitorTask?.cancel(); audioMonitorTask = nil
        if let audioCapture { Task { await audioCapture.stop() } }
        audioCapture = nil
        recognizingSpeech = false; audioLevel = 0
        speechStatus = "已暂停监听"
        translationScheduler.cancel()
        latestFrame = nil
        if let capture { Task { await capture.stop() } }
        capture = nil
    }
    func stop() {
        cancelWork()
        engine = nil
        isActive = false; isPaused = false
        original = ""; translated = ""
        translationHint = ""
        cache.removeAll(); cacheOrder.removeAll()
        region = nil
        listeningApplication = nil
        listeningName = ""
        speechRecognizer = nil
        audioWarning = ""
        speechStatus = "未开始监听"
        overlay?.orderOut(nil); overlay = nil
        status = "选择声音来源或字幕区域，开始实时翻译"
        hasError = false
        onStateChange?()
    }
    func screenConfigurationChanged() {
        guard isActive else { return }
        let audio = isAudioSession
        stop()
        report(audio ? "显示器配置已变化，请重新开始应用音频翻译。" : "显示器配置已变化，请重新框选字幕区域。")
        showSettings()
    }
    private func showOverlay(screen: NSScreen, rect: CGRect) {
        let visible = screen.visibleFrame
        let width = min(max(rect.width, 520), visible.width - 32)
        let height: CGFloat = 230
        let x = min(max(screen.frame.minX + rect.midX - width / 2, visible.minX + 16), visible.maxX - width - 16)
        let y = min(max(screen.frame.minY + rect.maxY + 12, visible.minY + 16), visible.maxY - height - 16)
        let panel = NSPanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 360, height: 150)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = settings.clickThrough
        panel.contentView = NSHostingView(rootView: SubtitleOverlayView(controller: self))
        panel.orderFrontRegardless()
        overlay = panel
    }
    func installModels() {
        guard let resources else { return }
        let script = resources.appendingPathComponent("setup.sh")
        install(script: script, message: "正在准备离线环境和四个语言包，首次下载可能需要几分钟…")
    }
    func installSpeechModel() {
        guard let resources = Bundle.main.resourceURL else { return }
        install(script: resources.appendingPathComponent("Speech/setup.sh"), message: "正在准备本地中英日语音模型（约 181 MiB），首次下载需要联网…")
    }
    private func install(script: URL, message: String) {
        guard !installing, !isActive else { return }
        installing = true; hasError = false; status = message
        Task {
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/bin/bash")
                        process.arguments = [script.path]
                        let pipe = Pipe()
                        process.standardOutput = pipe; process.standardError = pipe
                        try process.run()
                        let output = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else {
                            throw TranslationFailure(String((String(data: output, encoding: .utf8) ?? "离线环境安装失败").suffix(1200)))
                        }
                        continuation.resume(returning: .success(()))
                    } catch { continuation.resume(returning: .failure(error)) }
                }
            }
            installing = false
            refreshModels()
            switch result {
            case .success: status = "模型准备完成，可以开始实时翻译。"
            case .failure(let error): report(error.localizedDescription)
            }
        }
    }
}

private struct SubtitleOverlayView: View {
    @ObservedObject var controller: SubtitleController
    private var horizontal: HorizontalAlignment {
        switch controller.settings.horizontalAlignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
    private var textAlignment: TextAlignment {
        switch controller.settings.horizontalAlignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
    private var placement: Alignment {
        let vertical: VerticalAlignment
        switch controller.settings.verticalAlignment {
        case .top: vertical = .top
        case .center: vertical = .center
        case .bottom: vertical = .bottom
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
    private var placeholder: String {
        if controller.isPaused { return "已暂停" }
        if controller.original.isEmpty { return controller.isAudioSession ? controller.speechStatus : "等待字幕…" }
        return controller.translationHint.isEmpty ? "正在翻译…" : controller.translationHint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(controller.hasError ? "翻译已暂停" : (controller.isAudioSession ? controller.listeningName + " · " + controller.speechStatus : controller.status))
                    .font(.caption).lineLimit(1).help(controller.status)
                Spacer()
                Button(controller.isPaused ? "继续" : "暂停") { controller.togglePause() }
                Button(controller.isAudioSession ? "来源" : "重选") {
                    if controller.isAudioSession { controller.showSettings() }
                    else { controller.onSelect?() }
                }
                Button { controller.stop() } label: { Image(systemName: "xmark") }
            }.font(.caption).foregroundStyle(.white.opacity(0.7)).buttonStyle(.plain)
            if controller.hasError { Text(controller.status).font(.callout).foregroundStyle(.orange) }
            if controller.isAudioSession {
                ProgressView(value: controller.audioLevel).tint(.green).frame(height: 3)
                if !controller.audioWarning.isEmpty { Text(controller.audioWarning).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: horizontal, spacing: 8) {
                        if controller.settings.showOriginal, !controller.original.isEmpty {
                            Text(controller.original).font(.system(size: max(13, controller.settings.fontSize * 0.65)))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: horizontal, vertical: .center))
                        }
                        Text(controller.translated.isEmpty ? placeholder : controller.translated)
                            .font(.system(size: controller.settings.fontSize, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: horizontal, vertical: .center))
                    }
                    .multilineTextAlignment(textAlignment)
                    .opacity(controller.settings.textOpacity)
                    .frame(minHeight: geometry.size.height, alignment: placement)
                }
            }
        }.padding(16).background(.black.opacity(controller.settings.opacity), in: RoundedRectangle(cornerRadius: 12))
    }
}
