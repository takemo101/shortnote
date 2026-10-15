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

    @Test("確定した文字は、確定したときの大きさのまま。変えた文字サイズは、次の入力から効く")
    func committedTextKeepsItsSize() throws {
        let (host, editor) = makeEditor()
        _ = try begin(editor, in: host, size: 24, text: "one")
        let first = try #require(editor.finish())
        editor.setFontSize(96)                       // 入力欄が無いので、確定した文字には届かない
        _ = try begin(editor, in: host, size: 96, text: "two")
        let second = try #require(editor.finish())
        #expect(first.fontSize == 24)
        #expect(second.fontSize == 96)
    }

    @Test("既定の文字サイズは、選べる大きさの中にある。選べる大きさは、小さい順で重複がない")
    func presetsAreSortedAndContainDefault() {
        #expect(TextSize.presets.contains(TextSize.default))
        #expect(TextSize.presets == TextSize.presets.sorted())
        #expect(Set(TextSize.presets).count == TextSize.presets.count)
    }
}
