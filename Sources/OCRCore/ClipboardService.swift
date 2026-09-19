import AppKit

public enum ClipboardService {
    /// The check confirms the immediate write, not ownership forever.
    @MainActor public static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        return pasteboard.string(forType: .string) == text
    }
}
