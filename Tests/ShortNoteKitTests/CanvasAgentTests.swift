import AppKit
import Testing
@testable import ShortNoteKit

/// エージェントの操作が、人の入力・ドラッグの途中でも、それを壊さず、取り消しが確定した順に積まれること（SPEC §3.7）。
@Suite("キャンバス：エージェントの操作と、人の操作の重なり")
@MainActor
struct CanvasAgentTests {
    private func makeCanvas() -> CanvasView {
        CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    }

    private func rectItem(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 100, _ h: CGFloat = 60) -> Item {
        Item(content: .rect(CGRect(x: x, y: y, width: w, height: h)), color: CGColor(gray: 0, alpha: 1), size: 4)
    }

    private func mouse(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func down(_ c: CanvasView, _ p: CGPoint) throws { c.mouseDown(with: try mouse(.leftMouseDown, c, p)) }
    private func drag(_ c: CanvasView, _ p: CGPoint) throws { c.mouseDragged(with: try mouse(.leftMouseDragged, c, p)) }
    private func up(_ c: CanvasView, _ p: CGPoint) throws { c.mouseUp(with: try mouse(.leftMouseUp, c, p)) }

    private func minX(_ item: Item) -> CGFloat { item.bounds.minX }

    @Test("足した要素は、手前に重なり、1 回の要求が取り消しの 1 段")
    func appendIsOneUndoStep() {
        let canvas = makeCanvas()
        canvas.appendFromAgent([rectItem(10, 10), rectItem(20, 20)])
        #expect(canvas.document.items.count == 2)
        canvas.appendFromAgent([])   // 何も足さないとき、段を作らない
        canvas.undo()
        #expect(canvas.document.items.isEmpty)
        canvas.redo()
        #expect(canvas.document.items.count == 2)
    }

    @Test("移動のドラッグ中に足しても、動かしている要素は人のドラッグのとおりに動き続け、足した要素は残る。取り消しは、足したあと・動かした順")
    func appendDuringMoveDrag() throws {
        let canvas = makeCanvas()
        canvas.appendFromAgent([rectItem(100, 100)])
        canvas.tool = .move
        let original = minX(canvas.document.items[0])

        try down(canvas, CGPoint(x: 150, y: 130))
        try drag(canvas, CGPoint(x: 190, y: 130))
        #expect(minX(canvas.document.items[0]) == original + 40)

        canvas.appendFromAgent([rectItem(300, 200)])   // ドラッグの途中
        #expect(canvas.document.items.count == 2)
        #expect(canvas.isInteracting)
        #expect(canvas.committedDocument.items.count == 2 && minX(canvas.committedDocument.items[0]) == original)   // 確定済みは、動かす前の位置

        try drag(canvas, CGPoint(x: 210, y: 130))      // 足したあとのドラッグ：消えない
        #expect(canvas.document.items.count == 2)
        #expect(minX(canvas.document.items[0]) == original + 60)
        try up(canvas, CGPoint(x: 210, y: 130))
        #expect(!canvas.isInteracting)

        canvas.undo()   // 動かしたのを戻す（足した要素は残る）
        #expect(canvas.document.items.count == 2 && minX(canvas.document.items[0]) == original)
        canvas.undo()   // 足したのを戻す
        #expect(canvas.document.items.count == 1)
        canvas.undo()
        #expect(canvas.document.items.isEmpty)
    }

    @Test("入力中の文字は、足されても続き、確定すると、足した要素の上に重なる。取り消しは、文字が先")
    func appendDuringTextEditing() throws {
        let canvas = makeCanvas()
        canvas.tool = .text
        canvas.beginText(at: CGPoint(x: 10, y: 10))
        let tv = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        tv.string = "memo"

        canvas.appendFromAgent([rectItem(100, 100)])
        #expect(canvas.isEditing && canvas.isInteracting)
        #expect(tv.string == "memo")
        #expect(canvas.document.items.count == 1 && canvas.committedDocument.items.count == 1)   // 入力中の文字は、確定していない

        canvas.commitEditing()
        #expect(canvas.document.items.count == 2)
        guard case .text(let text, _) = canvas.document.items[1].content else { Issue.record("手前が文字でない"); return }
        #expect(text == "memo")
        canvas.undo()
        #expect(canvas.document.items.count == 1)
        canvas.undo()
        #expect(canvas.document.items.isEmpty)
    }

    @Test("ドラッグ中の線は、足されても続き、確定すると、足した要素の上に重なる")
    func appendDuringPenDrag() throws {
        let canvas = makeCanvas()
        canvas.tool = .pen
        try down(canvas, CGPoint(x: 10, y: 10))
        try drag(canvas, CGPoint(x: 60, y: 60))
        canvas.appendFromAgent([rectItem(200, 100)])
        #expect(canvas.isInteracting)
        try drag(canvas, CGPoint(x: 90, y: 40))
        try up(canvas, CGPoint(x: 90, y: 40))
        #expect(canvas.document.items.count == 2)
        guard case .pen(let points) = canvas.document.items[1].content else { Issue.record("手前がペンでない"); return }
        #expect(points.count >= 3)   // 足す前の点も、足したあとの点も、残っている
        canvas.undo()
        #expect(canvas.document.items.count == 1)
    }

    @Test("clear：確定済みの要素だけを消す。入力中の文字は残り、確定すると足される。取り消しで戻る")
    func clearKeepsTextBeingTyped() throws {
        let canvas = makeCanvas()
        canvas.appendFromAgent([rectItem(100, 100)])
        canvas.tool = .text
        canvas.beginText(at: CGPoint(x: 10, y: 10))
        let tv = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        tv.string = "keep"

        #expect(canvas.clearFromAgent())
        #expect(canvas.document.items.isEmpty && canvas.isEditing && tv.string == "keep")
        canvas.commitEditing()
        #expect(canvas.document.items.count == 1)
        canvas.undo()
        #expect(canvas.document.items.isEmpty)
        canvas.undo()
        #expect(canvas.document.items.count == 1)   // clear の取り消し
    }

    @Test("clear：移動のドラッグ中は、動かしている要素も消え、ドラッグは終わる。取り消すと、動かす前の位置で戻る")
    func clearDuringMoveDrag() throws {
        let canvas = makeCanvas()
        canvas.appendFromAgent([rectItem(100, 100)])
        canvas.tool = .move
        let original = minX(canvas.document.items[0])
        try down(canvas, CGPoint(x: 150, y: 130))
        try drag(canvas, CGPoint(x: 190, y: 130))

        #expect(canvas.clearFromAgent())
        #expect(canvas.document.items.isEmpty && !canvas.isInteracting)
        try drag(canvas, CGPoint(x: 230, y: 130))   // 続きのドラッグは、何も壊さない
        try up(canvas, CGPoint(x: 230, y: 130))
        #expect(canvas.document.items.isEmpty)

        canvas.undo()
        #expect(canvas.document.items.count == 1 && minX(canvas.document.items[0]) == original)
    }

    @Test("clear：消すものが無いときは false で、履歴に積まない")
    func clearNothing() {
        let canvas = makeCanvas()
        #expect(!canvas.clearFromAgent())
        canvas.appendFromAgent([rectItem(10, 10)])
        canvas.undo()
        canvas.undo()   // 積まれていれば、ここで何かが変わる
        #expect(canvas.document.items.isEmpty)
    }

    @Test("書き出す内容は、確定済みだけ。動かしている途中の位置は含めない")
    func committedExportIgnoresDragInProgress() throws {
        let canvas = makeCanvas()
        canvas.appendFromAgent([rectItem(100, 100)])
        canvas.tool = .move
        try down(canvas, CGPoint(x: 150, y: 130))
        try drag(canvas, CGPoint(x: 250, y: 130))
        let during = try #require(canvas.renderCommittedPNG())
        try up(canvas, CGPoint(x: 250, y: 130))
        canvas.undo()   // 動かす前に戻す
        let before = try #require(canvas.renderCommittedPNG())
        #expect(during == before)   // 途中の書き出しは、動かす前と同じ
    }
}
