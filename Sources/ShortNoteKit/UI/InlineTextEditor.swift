import AppKit

/// キャンバス上に重ねる、文字の入力欄。入力の途中の状態だけを持ち、確定した文字は `Entry` として返す
/// （キャンバスに要素を足すのは、呼び出し側）。
final class InlineTextEditor: NSObject, NSTextViewDelegate {
    /// 確定した文字。
    struct Entry {
        let text: String
        /// 文字ボックスの左上。
        let anchor: CGPoint
        let fontSize: CGFloat
        let color: CGColor
    }

    private weak var host: NSView?
    private var textView: NSTextView?
    private var anchor = CGPoint.zero
    private var fontSize: CGFloat = 18
    private var color = CGColor(gray: 0, alpha: 1)

    /// Return で確定を求められたとき（Shift／Option+Return は改行）。
    var onCommitRequested: (() -> Void)?

    init(host: NSView) {
        self.host = host
    }

    var isActive: Bool { textView != nil }

    /// 日本語入力などの変換中か。変換中のキーは、入力システムのもの。
    var hasMarkedText: Bool { textView?.hasMarkedText() == true }

    func begin(at point: CGPoint, fontSize: CGFloat, color: CGColor) {
        guard let host else { return }
        self.anchor = point
        self.fontSize = fontSize
        self.color = color

        let lineHeight = ceil(fontSize * 1.3)
        let tv = NSTextView(frame: NSRect(x: point.x, y: point.y, width: 40, height: lineHeight))
        let nsColor = NSColor(cgColor: color) ?? .black
        tv.delegate = self
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        tv.textColor = nsColor
        tv.insertionPointColor = nsColor
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1e5, height: 1e5)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        host.addSubview(tv)
        textView = tv
        host.window?.makeFirstResponder(tv)
    }

    /// 入力を終えて、入力欄を取り除く。空（空白だけ）なら `nil`。
    func finish() -> Entry? {
        guard let tv = textView else { return nil }
        let text = tv.string
        close()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Entry(text: text, anchor: anchor, fontSize: fontSize, color: color)
    }

    /// 入力を取り消して、入力欄を取り除く。
    func cancel() {
        close()
    }

    private func close() {
        guard let tv = textView else { return }
        textView = nil
        tv.removeFromSuperview()
        host?.window?.makeFirstResponder(host)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let host, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let w = min(max(used.width + 8, 40), max(40, host.bounds.width - anchor.x))
        let h = max(ceil(used.height), ceil(fontSize * 1.3))
        tv.frame = NSRect(x: anchor.x, y: anchor.y, width: w, height: h)
    }

    /// Return で確定、Shift／Option+Return で改行。IME 変換中の Return は変換の確定に使われ、ここには来ない。
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
        } else {
            onCommitRequested?()
        }
        return true
    }
}
