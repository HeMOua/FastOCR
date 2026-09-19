# FastOCR

macOS 原生菜单栏 OCR 工具：**⌘⇧O → 框选 → 本地识别 → 自动复制**。

## 使用

需要 macOS 14 或更新版本。打开 `dist/FastOCR.app`，菜单栏会出现取字图标。

1. 按 **⌘⇧O**，首次使用时按照提示授予「屏幕录制」权限，然后退出并重新打开应用。
2. 拖动框选文字，松开鼠标识别；**Esc** 取消。过小选区可重新拖动。
3. 看到「已复制」提示后，在目标应用按 **⌘V**。框选屏幕右下角会预览最多 4 行识别文本，6 秒后自动消失。
4. 菜单栏 →「查看上次结果」可查看、选中或复制文字。关闭「识别后自动复制」后，识别完成直接显示结果。

支持简体中文、繁体中文和英文。支持多屏和 Retina，每次在一个显示器内框选，不支持跨屏拼接。热键冲突时会提示，可继续从菜单栏启动识别。

截图和结果仅保存在内存中，不上传、不写入历史文件。剪贴板由系统管理，退出应用不会清空已复制内容。空白识别或失败不会覆盖已有剪贴板及上次成功结果。系统屏幕录制权限由用户手动授予，无需辅助功能权限。

## 构建与开发

安装 Xcode 或匹配的 Apple 开发工具，Swift 5.9+：

```sh
./scripts/build.sh
open dist/FastOCR.app
```

构建脚本生成本机架构的 Release 应用，默认使用本地 ad-hoc 签名。建议将应用放在固定位置使用。更新本地签名构建后，macOS 可能要求重新授予录屏权限。

```sh
swift test
open Package.swift
```

`swift test` 包含真实 Vision 中英文图片识别、空白图片、Retina 翻转、外接屏比例和越界裁剪测试。通过 Xcode 打开 Package.swift 可调试源码；日常使用应启动打包后的 `.app`，以便系统正确识别权限归属。

## 结构

- `Sources/OCRCore`：可替换的 `OCREngine`、Vision 实现、带置信度和坐标的结构化结果、坐标换算。
- `Sources/FastOCR/Capture.swift`：ScreenCaptureKit 静态截图，每屏独立选区面板。
- `Sources/FastOCR/GlobalHotkey.swift`：Carbon 系统热键。
- `Sources/FastOCR/FastOCRApp.swift`：菜单栏、权限引导、流程状态、剪贴板、HUD、SwiftUI 结果窗口。
- `Resources/Info.plist`、`scripts/build.sh`：应用元数据与打包。

先冻结屏幕，再在截图上绘制蒙层；按截图实际像素尺寸裁剪，避免蒙层入图与 Retina 模糊。Vision 在后台执行，主线程保持响应。结果沿用 Vision 文本块顺序，复杂多栏、代码缩进和表格不保证原版式还原。

## 手动验收

- 首次启动、拒绝录屏权限、授权后重启均有清晰行为。
- ⌘⇧O 或菜单启动，拖选、反向拖选、Esc、极小选区均能恢复。
- 英文、中文、深色背景文字识别并复制；空白区域不覆盖剪贴板。
- 自动复制开关重启后保留，结果窗口支持复制全文。
- 分别在 Retina 内屏和普通外接屏框选，包含位于主屏左侧/上方的显示器。
- 全屏应用上框选、连续触发热键、选区期间断开显示器。

## 当前边界

V0.1 未包含自定义快捷键、开机启动、持久化历史、PaddleOCR、表格解析或 AI 翻译。当前产物用于本机运行；对外分发需要 Developer ID 签名和 Apple 公证，可通过 `CODE_SIGN_IDENTITY` 为构建脚本指定签名身份。

截图 API 参考：[Apple SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)。


## V0.1.2 响应与复制改进

- 快捷键不再固定等待 180 毫秒；各显示器并发截图，仍保持整组画面准备好后进入选区。
- 菜单栏即时显示准备/识别状态；截图排除应用自身窗口，避免菜单、结果提示进入截图。
- 屏幕配置变化会取消正在准备的选区；裁剪失败单独提示，不再当成用户取消。
- 自动复制开关按本次识别开始时的状态执行。自动与手动复制共用写入、即时回读校验；失败明确提示，结果仍可查看。
- 回读只能确认写入当时的结果，无法阻止其他软件之后改写剪贴板。写入失败也可能发生在清空之后；本版不会尝试恢复其他应用提供的旧剪贴板数据。

性能诊断采用 macOS 统一日志，子系统 `com.chenchao.FastOCR`、类别 `performance`，记录枚举耗时、各屏截图耗时、选区准备耗时、OCR 耗时和复制是否成功，不记录图片或识别正文。可在「控制台」启用信息消息并按子系统过滤，或执行：

```sh
log stream --level info --predicate 'subsystem == "com.chenchao.FastOCR" AND category == "performance"'
```

`selection_ready_ms` 是快捷键处理开始到准备展示选区的耗时，不包含显示器实际呈现延迟；真实速度仍取决于系统截图服务及显示器配置。剪贴板测试使用独立测试剪贴板，不改写用户剪贴板。
