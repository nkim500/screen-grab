import AppKit
import CoreGraphics

public final class TextInserter {
    public init() {}

    public func insert(_ text: String) {
        NSLog("[screen-grab][paste] insert called len=\(text.count) sample=\"\(text.prefix(80))\"")
        let saved = saveClipboard()
        setClipboard(text)
        // Confirm the pasteboard got what we set — separates "we never told
        // the pasteboard" from "pasteboard accepted it but Cmd+V landed
        // somewhere unexpected."
        let confirm = NSPasteboard.general.string(forType: .string) ?? "<nil>"
        NSLog("[screen-grab][paste] clipboard set, readback len=\(confirm.count)")
        synthesizeCmdV()
        // Restore after the paste has had time to land in the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [saved] in
            self.restoreClipboard(saved)
        }
    }

    /// Strip an exact seed prefix from `text` IF doing so leaves
    /// non-whitespace content behind. Pure function; testable in isolation.
    ///
    /// Why this exists: the model sometimes echoes the focused field's text
    /// at the start of its draft. Pasting that verbatim duplicates the
    /// seed. But if stripping leaves "" or only whitespace, we'd silently
    /// paste nothing — which looks like Enter is broken. Better to paste
    /// the full draft and let the user delete a duplicate than to silently
    /// paste empty.
    public static func dedupAgainstSeed(text: String, seed: String) -> String {
        // No seed → nothing to dedup.
        if seed.isEmpty { return text }
        // Model output doesn't start with seed → no echo to strip.
        if !text.hasPrefix(seed) { return text }
        let stripped = String(text.dropFirst(seed.count))
        // Strip would leave nothing useful → fall back to full text.
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return stripped
    }

    private func saveClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func restoreClipboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if snapshot.isEmpty { return }
        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }

    private func synthesizeCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
