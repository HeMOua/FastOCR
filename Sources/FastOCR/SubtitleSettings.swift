import AppKit
import SwiftUI
import Security
import OCRCore

enum SubtitleKeychain {
    private static func query(_ appID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.chenchao.FastOCR.baidu-translation",
         kSecAttrAccount as String: appID]
    }
    static func read(appID: String) -> String {
        var query = query(appID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, appID: String) throws {
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationFailure("请先填写百度翻译 APP ID。")
        }
        let query = query(appID)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TranslationFailure("无法清除钥匙串中的密钥（\(status)）") }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TranslationFailure("无法保存 API 密钥到钥匙串（\(status)）") }
    }
}

struct SubtitleSettingsView: View {
    @ObservedObject var controller: SubtitleController
    @State private var apiKey = ""
    @State private var keyStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform.bubble").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("实时翻译").font(.title2.bold())
                    Text("应用音频与屏幕字幕，共用一个翻译窗口").foregroundStyle(.secondary)
                }
            }
            Form {
                Section("翻译来源") {
                    Picker("来源", selection: $controller.settings.inputMode) {
                        ForEach(TranslationInputMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(controller.isActive)
                    if controller.settings.inputMode == .applicationAudio {
                        HStack {
                            Picker("应用", selection: $controller.selectedApplicationID) {
                                Text("选择正在播放声音的应用").tag(Int32(0))
                                ForEach(controller.applications) { Text($0.name).tag($0.id) }
                            }
                            Button("刷新") { controller.refreshApplications() }
                        }.disabled(controller.isActive)
                        Text("只监听所选应用的播放声音，不启用麦克风。浏览器按应用捕获，可能包含多个标签页。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Label(controller.speechModelsReady ? "本地语音模型已就绪" : "需要准备语音模型", systemImage: controller.speechModelsReady ? "checkmark.circle" : "arrow.down.circle")
                            Spacer()
                            Button(controller.installing ? "准备中…" : "准备语音模型") { controller.installSpeechModel() }
                                .disabled(controller.installing || controller.isActive)
                        }
                        HStack {
                            Text("最长识别片段")
                            Slider(value: $controller.settings.audioSegmentSeconds, in: 2...6, step: 0.5)
                            Text(String(format: "%.1f 秒", controller.settings.audioSegmentSeconds)).monospacedDigit()
                        }.disabled(controller.isActive)
                        Text("停顿时提前识别；短片段响应更快，长片段更利于完整句子。语音识别在本机完成。")
                            .font(.caption).foregroundStyle(.secondary)
                        if controller.isAudioSession {
                            HStack {
                                Text("声音电平")
                                ProgressView(value: controller.audioLevel).tint(.green)
                            }
                            Text(controller.speechStatus).font(.caption)
                            if controller.speechMilliseconds > 0 {
                                Text("上一段识别耗时 \(controller.speechMilliseconds) 毫秒").font(.caption).foregroundStyle(.secondary)
                            }
                            if !controller.audioWarning.isEmpty {
                                Text(controller.audioWarning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("框选一至两行字幕，固定区域持续识别；播放器移动后请重新框选。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("翻译语言") {
                    Picker("来源语言", selection: $controller.settings.source) {
                        ForEach(SubtitleLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("翻译为", selection: $controller.settings.target) {
                        ForEach(SubtitleLanguage.targets) { Text($0.title).tag($0) }
                    }
                    Text("固定语言的视频建议手动指定来源语言，减少短句误判。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(controller.isActive)
                Section("翻译方式") {
                    Picker("引擎", selection: $controller.settings.online) {
                        Text("本地离线").tag(false)
                        Text("百度机器翻译").tag(true)
                    }.pickerStyle(.segmented).disabled(controller.isActive)
                    if controller.settings.online {
                        TextField("百度翻译 APP ID", text: $controller.settings.baiduAppID)
                        HStack {
                            SecureField("百度翻译密钥", text: $apiKey)
                            Button("保存密钥") {
                                do { try SubtitleKeychain.save(apiKey, appID: controller.settings.baiduAppID); keyStatus = "已保存到系统钥匙串" }
                                catch { keyStatus = error.localizedDescription }
                            }
                        }
                        if !keyStatus.isEmpty { Text(keyStatus).font(.caption) }
                        HStack {
                            Text("请求间隔")
                            Slider(value: $controller.settings.requestInterval, in: 0.1...5, step: 0.1)
                            Text(String(format: "%.1f 秒", controller.settings.requestInterval)).monospacedDigit()
                        }
                        Text("默认每 1.1 秒最多发起一次请求。降低间隔前，请确认你的账户调用限额。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("使用百度通用文本翻译 API，只发送字幕文字。APP ID 和密钥来自百度翻译开放平台。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Label(controller.modelsReady ? "离线模型已安装" : "首次使用需要准备模型", systemImage: controller.modelsReady ? "checkmark.circle" : "arrow.down.circle")
                            Spacer()
                            Button(controller.installing ? "准备中…" : "准备离线模型") { controller.installModels() }
                                .disabled(controller.installing || controller.isActive)
                        }
                        Text("首次下载需要联网，建议预留 1 GB 空间；完成后可断网使用。简繁直接转换，中日翻译经英文中转；翻成日文的质量较弱。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(controller.isActive)
                Section("响应速度") {
                    HStack {
                        Text("单句最长等待")
                        Slider(value: $controller.settings.translationTimeout, in: 1...10, step: 0.5)
                        Text(String(format: "%.1f 秒", controller.settings.translationTimeout)).monospacedDigit()
                    }
                    Text("这是文字翻译等待时间，不含语音分段和识别。过期请求会取消，超时跳过本句。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("字幕显示") {
                    Toggle("显示原字幕", isOn: $controller.settings.showOriginal)
                    HStack { Text("字号"); Slider(value: $controller.settings.fontSize, in: 16...40, step: 1); Text("\(Int(controller.settings.fontSize))").monospacedDigit() }
                    transparencyRow("背景透明度", opacity: $controller.settings.opacity)
                    transparencyRow("文字透明度", opacity: $controller.settings.textOpacity)
                    Picker("水平位置", selection: $controller.settings.horizontalAlignment) {
                        ForEach(SubtitleHorizontalAlignment.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("垂直位置", selection: $controller.settings.verticalAlignment) {
                        ForEach(SubtitleVerticalAlignment.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("位置相对于字幕窗口；拖动窗口背景可移动整个字幕窗。显示设置立即生效。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("鼠标穿透（从菜单栏暂停或结束）", isOn: $controller.settings.clickThrough)
                }
            }.formStyle(.grouped)
            Text(controller.status).font(.callout).foregroundStyle(controller.hasError ? .red : .secondary)
                .textSelection(.enabled).lineLimit(4)
            if controller.isActive {
                Text("修改语言或翻译方式前，请先结束翻译。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if controller.isActive {
                    Button(controller.isPaused ? "继续" : "暂停") { controller.togglePause() }
                    Button("结束翻译") { controller.stop() }
                }
                Spacer()
                Button(controller.settings.inputMode == .applicationAudio ? (controller.isActive ? "重新开始监听" : "开始应用音频翻译") : (controller.isActive ? "重新框选" : "框选字幕区域")) {
                    if controller.settings.inputMode == .applicationAudio { controller.onStartAudio?() }
                    else { controller.onSelect?() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canStart)
            }
        }.padding(22).frame(width: 550, height: 690)
        .onAppear { apiKey = SubtitleKeychain.read(appID: controller.settings.baiduAppID); controller.refreshModels(); controller.refreshApplications() }
        .onChange(of: controller.settings.baiduAppID) { _, appID in
            apiKey = SubtitleKeychain.read(appID: appID)
            keyStatus = ""
        }
    }
    private func transparencyRow(_ title: String, opacity: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(get: { 1 - opacity.wrappedValue }, set: { opacity.wrappedValue = 1 - $0 }), in: 0...1)
            Text("\(Int(((1 - opacity.wrappedValue) * 100).rounded()))%").monospacedDigit().frame(width: 42, alignment: .trailing)
        }
    }

}
