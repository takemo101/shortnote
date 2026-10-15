import AppKit
import Testing
@testable import ShortNoteKit

@Suite("文字サイズ")
@MainActor
struct TextSizeTests {
    private func makeEditor() -> (host: NSView, editor: InlineTextEditor) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        return (host, InlineTextEditor(host: host))
    }

    /// 入力欄を開いて、文字を入れる。
    private func begin(_ editor: InlineTextEditor, in host: NSView, size: CGFloat, text: String) throws -> NSTextView {
        editor.begin(at: CGPoint(x: 10, y: 10), fontSize: size, color: CGColor(gray: 0, alpha: 1))
        let tv = try #require(host.subviews.compactMap { $0 as? NSTextView }.first)
        tv.string = text
        tv.didChangeText()
        return tv
    }

    @Test("入力中に文字サイズを変えると、入力欄の高さと、確定する文字の大きさが変わる")
    func changingSizeWhileEditing() throws {
        let (host, editor) = makeEditor()
        let tv = try begin(editor, in: host, size: 18, text: "abc")
        let before = tv.frame.height

        editor.setFontSize(64)

        #expect(tv.frame.height > before)
        #expect(tv.frame.height >= ceil(64 * 1.3))
        #expect(tv.font?.pointSize == 64)
        let entry = try #require(editor.finish())
        #expect(entry.fontSize == 64)
        #expect(entry.text == "abc")
    }

    @Test("入力欄が無いときに文字サイズを変えても、何も起きない")
    func changingSizeWithoutEditing() {
        let (_, editor) = makeEditor()
        editor.setFontSize(48)
        #expect(!editor.isActive)
        #expect(editor.finish() == nil)
    }

    /// 文字を入れて確定した、最後の文字の要素（大きさ、枠）。
    private func commitText(_ canvas: CanvasView, _ text: String) throws -> (size: CGFloat, box: CGRect) {
        let tv = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        tv.string = text
        canvas.commitEditing()
        let item = try #require(canvas.document.items.last)
        guard case .text(_, let box) = item.content else { Issue.record("最後の要素が文字ではない"); throw CancellationError() }
        return (item.size, box)
    }

    @Test("文字は、ブラシサイズではなく、文字サイズの大きさで確定する")
    func committedTextFollowsTheTextSizeNotTheBrush() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.brushSize = 30          // 連動していた頃なら、12 + 30 × 1.5 = 57 pt になる
        canvas.textSize = 48
        canvas.beginText(at: CGPoint(x: 10, y: 10))
        let committed = try commitText(canvas, "abc")
        #expect(committed.size == 48)
        #expect(committed.box.height >= 48)
    }

    @Test("入力中に変えた大きさで確定し、確定したあとに変えても、確定した文字は変わらない。次の入力から新しい大きさになる")
    func liveChangeCommitsAndLaterChangesDoNotReachCommittedText() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.textSize = 18
        canvas.beginText(at: CGPoint(x: 10, y: 10))
        canvas.textSize = 64                       // 入力中に変える
        let first = try commitText(canvas, "one")

        canvas.textSize = 12                       // 確定したあと
        #expect(canvas.document.items.last.map(\.size) == 64)

        canvas.beginText(at: CGPoint(x: 10, y: 100))
        let second = try commitText(canvas, "two")
        #expect(first.size == 64)
        #expect(second.size == 12)
    }

    @Test("既定の文字サイズは、選べる大きさの中にある。選べる大きさは、小さい順で重複がない")
    func presetsAreSortedAndContainDefault() {
        #expect(TextSize.presets.contains(TextSize.default))
        #expect(TextSize.presets == TextSize.presets.sorted())
        #expect(Set(TextSize.presets).count == TextSize.presets.count)
    }
}
