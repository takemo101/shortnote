import AppKit
import Testing
@testable import ShortNoteKit

private let black = CGColor(gray: 0, alpha: 1)
private let canvasRect = CGRect(x: 0, y: 0, width: 480, height: 320)

private func rectItem(_ r: CGRect, size: CGFloat = 4) -> Item { Item(content: .rect(r), color: black, size: size) }
private func lineItem(_ a: CGPoint, _ b: CGPoint) -> Item { Item(content: .line(from: a, to: b), color: black, size: 4) }

@Suite("範囲選択とまとめて移動：文書（A33）")
struct MarqueeDocumentTests {
    @Test("範囲にすっぽり入った要素だけが選ばれる（外接する範囲。線の太さ込み）。一部が出ている要素・外の要素は選ばれない。小さい順")
    func containment() {
        let doc = Document().appending(contentsOf: [
            rectItem(CGRect(x: 20, y: 20, width: 40, height: 40)),          // bounds (18,18,44,44)
            rectItem(CGRect(x: 200, y: 200, width: 40, height: 40)),        // 範囲の外
            lineItem(CGPoint(x: 30, y: 30), CGPoint(x: 120, y: 30)),        // 右へはみ出す
            rectItem(CGRect(x: 70, y: 70, width: 20, height: 20)),
        ])
        #expect(doc.itemIndices(containedIn: CGRect(x: 10, y: 10, width: 100, height: 100), canvas: canvasRect) == [0, 3])
        #expect(doc.itemIndices(containedIn: CGRect(x: 10, y: 10, width: 120, height: 100), canvas: canvasRect) == [0, 2, 3])
        #expect(doc.itemIndices(containedIn: CGRect(x: 20, y: 20, width: 40, height: 40), canvas: canvasRect).isEmpty)   // 線の太さの分、はみ出す
        #expect(doc.itemIndices(containedIn: .zero, canvas: canvasRect).isEmpty)
    }

    @Test("キャンバスの縁に触れている要素は、縁まで引いた範囲で、選べる（縁の外へはみ出した線の太さの分は、数えない）。キャンバスの中に、まったく無い要素は、選ばれない")
    func itemsTouchingTheEdge() {
        let doc = Document().appending(contentsOf: [
            rectItem(CGRect(x: 0, y: 0, width: 50, height: 50)),            // bounds (-2,-2,54,54)：左上の縁に触れる
            rectItem(CGRect(x: 440, y: 280, width: 40, height: 40)),        // 右下の縁に触れる
            rectItem(CGRect(x: 600, y: 100, width: 40, height: 40)),        // キャンバスの外
            rectItem(CGRect(x: 200, y: 100, width: 40, height: 40)),
        ])
        #expect(doc.itemIndices(containedIn: canvasRect, canvas: canvasRect) == [0, 1, 3])
        #expect(doc.itemIndices(containedIn: CGRect(x: 0, y: 0, width: 60, height: 60), canvas: canvasRect) == [0])
    }

    @Test("まとめて動かす：同じだけ動く。どの要素も、16 pt の規則を満たす（離れた要素が、キャンバスの外へ完全に出て、掴めなくならない）。間隔は保たれる")
    func translatingTogether() throws {
        let a = rectItem(CGRect(x: 100, y: 100, width: 40, height: 40)), b = rectItem(CGRect(x: 300, y: 100, width: 40, height: 40))
        let doc = Document().appending(contentsOf: [a, b, rectItem(CGRect(x: 10, y: 10, width: 10, height: 10))])
        let moved = try #require(doc.translatingItems(at: [0, 1], by: CGSize(width: 30, height: 20), keepingGrabAreaIn: canvasRect))
        #expect(moved.items[0].bounds == a.bounds.offsetBy(dx: 30, dy: 20) && moved.items[1].bounds == b.translated(by: CGSize(width: 30, height: 20)).bounds)
        #expect(moved.items[2].bounds == doc.items[2].bounds)                                   // 選ばれていない要素は、動かない
        // 右へ大きく：いちばん右の b の、掴める範囲（外接する範囲＋4 pt）が、16 pt 残るまで。a も、同じだけ動く
        let far = try #require(doc.translatingItems(at: [0, 1], by: CGSize(width: 1000, height: 0), keepingGrabAreaIn: canvasRect))
        #expect(abs(far.items[1].bounds.minX - far.items[0].bounds.minX - 200) < 1e-9)           // 間隔は、そのまま
        let rightmost = far.items[1].bounds.insetBy(dx: -4, dy: -4)
        #expect(abs(rightmost.minX - (480 - 16)) < 1e-9)                                        // b の掴める範囲の、16 pt が残る位置で止まる
        #expect(far.items[0].bounds.minX == a.bounds.minX + (far.items[1].bounds.minX - b.bounds.minX))
        #expect(doc.translatingItems(at: [], by: .zero, keepingGrabAreaIn: canvasRect) == nil)
        #expect(doc.translatingItems(at: [9], by: .zero, keepingGrabAreaIn: canvasRect) == nil)
        #expect(try #require(doc.translatingItems(at: [0, 9], by: CGSize(width: 5, height: 0), keepingGrabAreaIn: canvasRect)).items[0].bounds.minX == a.bounds.minX + 5)   // 範囲外の番号は、除く
    }

    @Test("離れた 2 つ（左の縁と右の縁）を、まとめて、大きく動かしても、どちらも掴める範囲が、16 pt 残る（レビューの指摘：和集合にだけ規則を当てると、片方が消える）")
    func everyMemberStaysReachable() throws {
        let a = rectItem(CGRect(x: 10, y: 100, width: 40, height: 40)), b = rectItem(CGRect(x: 420, y: 100, width: 40, height: 40))
        let doc = Document().appending(contentsOf: [a, b])
        for d in [CGSize(width: -1000, height: 0), CGSize(width: 1000, height: 0), CGSize(width: 0, height: 1000), CGSize(width: 0, height: -1000), CGSize(width: -1000, height: 1000)] {
            let moved = try #require(doc.translatingItems(at: [0, 1], by: d, keepingGrabAreaIn: canvasRect))
            for item in moved.items {
                let area = item.bounds.insetBy(dx: -4, dy: -4).intersection(canvasRect)
                #expect(!area.isNull && area.width >= 16 - 1e-9 && area.height >= 16 - 1e-9, "d=\(d) bounds=\(item.bounds)")
            }
            #expect(abs(moved.items[1].bounds.minX - moved.items[0].bounds.minX - 410) < 1e-9 && abs(moved.items[1].bounds.minY - moved.items[0].bounds.minY) < 1e-9)
        }
    }

    @Test("変わったか：1 つでも変われば、変わった。動かなかったときは、変わらない")
    func hasChangedItems() throws {
        let doc = Document().appending(contentsOf: [rectItem(CGRect(x: 100, y: 100, width: 40, height: 40)), rectItem(CGRect(x: 200, y: 100, width: 40, height: 40))])
        let moved = try #require(doc.translatingItems(at: [0, 1], by: CGSize(width: 3, height: 0), keepingGrabAreaIn: canvasRect))
        #expect(moved.hasChangedItems(at: [0, 1], since: doc) && moved.hasChangedItems(at: [1], since: doc))
        #expect(!doc.hasChangedItems(at: [0, 1], since: doc) && !moved.hasChangedItems(at: [], since: doc))
    }
}

@Suite("範囲選択とまとめて移動：キャンバス（A33）")
@MainActor
struct MarqueeCanvasTests {
    private func canvas(_ items: [Item]) -> CanvasView {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.appendFromAgent(items)
        canvas.tool = .move
        return canvas
    }

    private func event(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint, shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func down(_ c: CanvasView, _ p: CGPoint, shift: Bool = false) throws { c.mouseDown(with: try event(.leftMouseDown, c, p, shift: shift)) }
    private func drag(_ c: CanvasView, _ p: CGPoint, shift: Bool = false) throws { c.mouseDragged(with: try event(.leftMouseDragged, c, p, shift: shift)) }
    private func up(_ c: CanvasView, _ p: CGPoint, shift: Bool = false) throws { c.mouseUp(with: try event(.leftMouseUp, c, p, shift: shift)) }
    private func swipe(_ c: CanvasView, from a: CGPoint, to b: CGPoint, shift: Bool = false) throws {
        try down(c, a, shift: shift); try drag(c, b, shift: shift); try up(c, b, shift: shift)
    }
    private func click(_ c: CanvasView, _ p: CGPoint) throws { try down(c, p); try up(c, p) }

    /// 3 つの要素：A（40,40）、B（140,40）、C（300,200）。どれも 40×40。
    private func three() -> CanvasView {
        canvas([rectItem(CGRect(x: 40, y: 40, width: 40, height: 40)), rectItem(CGRect(x: 140, y: 40, width: 40, height: 40)), rectItem(CGRect(x: 300, y: 200, width: 40, height: 40))])
    }

    @Test("何もない所からドラッグして、範囲にすっぽり入った要素だけが選ばれる。取り消しの段にはならない。範囲の途中は、操作の途中")
    func marqueeSelects() throws {
        let c = three()
        try down(c, CGPoint(x: 10, y: 10))
        try drag(c, CGPoint(x: 200, y: 100))
        #expect(c.isInteracting)
        try up(c, CGPoint(x: 200, y: 100))
        #expect(!c.isInteracting && c.selectedItems == [0, 1] && c.selectedItem == nil)
        c.undo()
        #expect(c.document.items.isEmpty)                                       // 最初の取り消しは、要素を足した段（範囲選択は、段ではない）
        c.redo()
        try swipe(c, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 160, y: 60))   // 2 つ目の要素の上から（Shift なし）：その要素を掴んで動かす
        #expect(c.selectedItems.count == 1)
    }

    @Test("一部だけ入る要素は選ばれない。何も入らなければ、選びは空。右下から左上へのドラッグも同じ")
    func partialAndEmpty() throws {
        let c = three()
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 60))    // A の途中まで
        #expect(c.selectedItems.isEmpty)
        try swipe(c, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 10, y: 10))    // 逆向き
        #expect(c.selectedItems == [0, 1])
        try swipe(c, from: CGPoint(x: 400, y: 300), to: CGPoint(x: 420, y: 310))
        #expect(c.selectedItems.isEmpty)
    }

    @Test("選ばれた要素のどれかを掴んでドラッグすると、全部が同じだけ動く。取り消しの 1 段で、全部戻る")
    func groupMove() throws {
        let c = three()
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        let before = c.document.items.map(\.bounds)
        try swipe(c, from: CGPoint(x: 160, y: 60), to: CGPoint(x: 190, y: 90))     // B の中（選ばれている）を掴んで、(+30, +30)
        #expect(c.document.items[0].bounds == before[0].offsetBy(dx: 30, dy: 30))
        #expect(c.document.items[1].bounds == before[1].offsetBy(dx: 30, dy: 30))
        #expect(c.document.items[2].bounds == before[2])                          // 選ばれていない C は、動かない
        #expect(c.selectedItems == [0, 1])                                         // 動かしたあとも、選ばれたまま
        c.undo()
        #expect(c.document.items.map(\.bounds) == before)                         // 1 段で、全部戻る
        #expect(c.selectedItems.isEmpty)
        c.redo()
        #expect(c.document.items[0].bounds == before[0].offsetBy(dx: 30, dy: 30) && c.document.items[1].bounds == before[1].offsetBy(dx: 30, dy: 30))
    }

    @Test("選ばれていない要素を掴むと、その 1 つだけの選びになり、その 1 つだけが動く。何もない所のクリックで、選びが外れる")
    func grabbingAnUnselectedItem() throws {
        let c = three()
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        let c0 = c.document.items[2].bounds
        try swipe(c, from: CGPoint(x: 320, y: 220), to: CGPoint(x: 330, y: 230))   // C
        #expect(c.selectedItem == 2 && c.document.items[2].bounds == c0.offsetBy(dx: 10, dy: 10))
        #expect(c.document.items[0].bounds == rectItem(CGRect(x: 40, y: 40, width: 40, height: 40)).bounds)
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        try click(c, CGPoint(x: 400, y: 300))
        #expect(c.selectedItems.isEmpty)
    }

    @Test("Shift を押して始めると、要素の上からでも範囲選択になる。大きな枠の中の部品を選べる。Shift なしでは、枠を動かす")
    func shiftStartsAMarqueeOverAnItem() throws {
        let frame = rectItem(CGRect(x: 20, y: 20, width: 400, height: 280))
        let a = rectItem(CGRect(x: 60, y: 60, width: 40, height: 40)), b = rectItem(CGRect(x: 160, y: 60, width: 40, height: 40))
        let c = canvas([frame, a, b])
        try swipe(c, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 250, y: 120), shift: true)   // 枠の上から、Shift つき
        #expect(c.selectedItems == [1, 2])                                                      // 枠そのものは、すっぽり入らないので、選ばれない
        #expect(c.document.items[0].bounds == frame.bounds)                                    // 枠は、動いていない
        let plain = canvas([frame, a, b])
        try swipe(plain, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 250, y: 120))             // Shift なし：枠を掴んで動かす
        #expect(plain.document.items[0].bounds == frame.bounds.offsetBy(dx: 210, dy: 80))
        #expect(plain.selectedItems == [0])
    }

    @Test("選ばれたグループは、キャンバスの外へ出てしまう位置へは動かない（全体に同じ制限）。間隔は保たれる")
    func groupStaysReachable() throws {
        let c = three()
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        let gap = c.document.items[1].bounds.minX - c.document.items[0].bounds.minX
        try swipe(c, from: CGPoint(x: 160, y: 60), to: CGPoint(x: 480, y: 60))                  // 右の縁まで（ポインタは縁に丸まる）
        let union = c.document.items[0].bounds.union(c.document.items[1].bounds)
        #expect(abs(c.document.items[1].bounds.minX - c.document.items[0].bounds.minX - gap) < 1e-9)
        #expect(union.insetBy(dx: -4, dy: -4).minX < 480 - 15)
    }

    @Test("ドラッグの途中で、エージェントが足した要素は残る。取り消しで、動かす前に戻る")
    func agentAppendDuringGroupMove() throws {
        let c = three()
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        let before = c.document.items.map(\.bounds)
        try down(c, CGPoint(x: 160, y: 60))
        try drag(c, CGPoint(x: 180, y: 70))
        c.appendFromAgent([rectItem(CGRect(x: 400, y: 20, width: 20, height: 20))])
        try drag(c, CGPoint(x: 200, y: 80))
        try up(c, CGPoint(x: 200, y: 80))
        #expect(c.document.items.count == 4)
        #expect(c.document.items[0].bounds == before[0].offsetBy(dx: 40, dy: 20))
        c.undo()
        #expect(c.document.items.count == 4 && c.document.items.prefix(3).map(\.bounds) == before)
    }

    @Test("ツールの切り替え・取り消し・クリアで、選びが外れる。範囲選択の途中でツールを替えても、壊れない")
    func selectionClears() throws {
        let c = three()
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        c.tool = .pen
        #expect(c.selectedItems.isEmpty)
        c.tool = .move
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        c.clearCanvas()
        #expect(c.selectedItems.isEmpty)
        c.undo()
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))
        #expect(c.clearFromAgent() && c.selectedItems.isEmpty)
    }

    @Test("範囲の枠・複数選択の枠は、書き出し PNG に入らない。選ぶ前と後で、書き出しは同じ")
    func notExported() throws {
        let c = three()
        let before = try #require(c.renderPNG())
        try down(c, CGPoint(x: 10, y: 10)); try drag(c, CGPoint(x: 200, y: 100))
        #expect(try #require(c.renderCommittedPNG()) == before)                          // 範囲選択の途中
        try up(c, CGPoint(x: 200, y: 100))
        #expect(c.selectedItems == [0, 1])
        #expect(try #require(c.renderPNG()) == before)                                   // 選んだあと
    }

    @Test("1 つだけ選ぶ（クリック）と、これまでどおり、取っ手が出る。複数のときは、取っ手が無い（回転の取っ手の位置を押しても、回らない）")
    func singleKeepsHandlesMultipleDoesNot() throws {
        let c = three()
        try click(c, CGPoint(x: 60, y: 60))
        #expect(c.selectedItem == 0)
        try swipe(c, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 100))                // 2 つ
        #expect(c.selectedItem == nil && c.selectedItems.count == 2)
        let before = c.document.items[0]
        // A の回転の取っ手の位置（上辺の中央の 24 pt 上）: 何もない所なので、範囲選択が始まるだけ
        try swipe(c, from: CGPoint(x: 60, y: 16), to: CGPoint(x: 70, y: 16))
        #expect(c.document.items[0].rotation == before.rotation && c.document.items[0].bounds == before.bounds)
    }
}

@Suite("範囲選択：途中の割り込み（レビューの指摘）")
@MainActor
struct MarqueeInterruptionTests {
    private func canvas() -> CanvasView {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.appendFromAgent([rectItem(CGRect(x: 40, y: 40, width: 40, height: 40)), rectItem(CGRect(x: 300, y: 200, width: 40, height: 40))])
        c.tool = .move
        return c
    }

    private func event(_ type: NSEvent.EventType, _ c: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: c.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("範囲選択の途中で、ツールを替えて、離しても、選びは空のまま（ペンのツールのまま、選ばれない）")
    func toolChangeDuringTheMarquee() throws {
        let c = canvas()
        c.mouseDown(with: try event(.leftMouseDown, c, CGPoint(x: 10, y: 10)))
        c.mouseDragged(with: try event(.leftMouseDragged, c, CGPoint(x: 200, y: 120)))
        #expect(c.isInteracting)
        c.tool = .pen
        #expect(!c.isInteracting)
        c.mouseUp(with: try event(.leftMouseUp, c, CGPoint(x: 200, y: 120)))
        #expect(c.selectedItems.isEmpty)
    }

    @Test("離す操作が届かなかった範囲選択が残っていても、次の mouseDown で捨てる（次のドラッグを、乗っ取らない）")
    func staleMarqueeIsDropped() throws {
        let c = canvas()
        c.mouseDown(with: try event(.leftMouseDown, c, CGPoint(x: 10, y: 10)))       // 何もない所：範囲選択の開始（離す操作は、来ない）
        c.mouseDown(with: try event(.leftMouseDown, c, CGPoint(x: 60, y: 60)))       // 次の操作：四角を掴む
        c.mouseDragged(with: try event(.leftMouseDragged, c, CGPoint(x: 90, y: 90)))
        c.mouseUp(with: try event(.leftMouseUp, c, CGPoint(x: 90, y: 90)))
        #expect(c.document.items[0].bounds == rectItem(CGRect(x: 70, y: 70, width: 40, height: 40)).bounds)   // 四角が、(+30,+30) 動いた
        #expect(!c.isInteracting && c.selectedItem == 0)
    }
}
