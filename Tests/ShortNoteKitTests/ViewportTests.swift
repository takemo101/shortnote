import AppKit
import Testing
@testable import ShortNoteKit

private let view = CGSize(width: 480, height: 320)

@Suite("ビューの移動と拡大縮小：値（A35）")
struct ViewportValueTests {
    @Test("倍率は、25%〜400%に収まる。有限でない値は、等倍・動かしていない状態に戻る")
    func zoomRange() {
        let tooBig = Viewport(zoom: 100, origin: .zero).clamped(viewSize: view)
        let tooSmall = Viewport(zoom: 0.001, origin: .zero).clamped(viewSize: view)
        #expect(tooBig.zoom == 4 && tooSmall.zoom == 0.25)
        #expect(Viewport(zoom: .nan, origin: .zero).clamped(viewSize: view) == .identity)
        #expect(Viewport(zoom: 1, origin: CGPoint(x: CGFloat.infinity, y: 0)).clamped(viewSize: view) == .identity)
        #expect(Viewport.identity.zoomed(by: 100, anchor: .zero, viewSize: view).zoom == 4)
        #expect(Viewport.identity.zoomed(by: -1, anchor: .zero, viewSize: view) == .identity)   // 負の倍率は、受け付けない
    }

    @Test("拡大縮小：ポインタの位置（anchor）にある点は、画面の同じ位置に残る")
    func anchorStaysPut() {
        let start = Viewport(zoom: 2, origin: CGPoint(x: 40, y: 30))
        let anchor = CGPoint(x: 100, y: 90)
        func screen(_ v: Viewport, _ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - v.origin.x) * v.zoom, y: (p.y - v.origin.y) * v.zoom) }
        for factor in [0.5, 1.5, 3.0] as [CGFloat] {
            let next = start.zoomed(by: factor, anchor: anchor, viewSize: view)
            let before = screen(start, anchor), after = screen(next, anchor)
            #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9, "factor=\(factor)")
        }
    }

    @Test("移動：内容が、指について動く（見えている範囲の左上は、逆向き）。倍率が高いほど、キャンバスでの動きは小さい")
    func panDirection() {
        let a = Viewport.identity.panned(byScreen: CGSize(width: 30, height: -20), viewSize: view)
        #expect(a.origin == CGPoint(x: -30, y: 20))
        let b = Viewport(zoom: 2, origin: CGPoint(x: 100, y: 100)).panned(byScreen: CGSize(width: 30, height: 10), viewSize: view)
        #expect(b.origin == CGPoint(x: 85, y: 95))
    }

    @Test("動かせる範囲：キャンバスが、ビューから、すっかり出てしまわない（画面で 64 pt は、見えている）。どの向きでも、どの倍率でも")
    func staysVisible() {
        for zoom in [0.25, 1, 4] as [CGFloat] {
            for far in [CGPoint(x: -1e6, y: -1e6), CGPoint(x: 1e6, y: 1e6), CGPoint(x: -1e6, y: 1e6), CGPoint(x: 1e6, y: -1e6)] {
                let v = Viewport(zoom: zoom, origin: far).clamped(viewSize: view)
                let visible = v.visibleRect(viewSize: view).intersection(CGRect(origin: .zero, size: view))
                #expect(!visible.isNull, "zoom=\(zoom) far=\(far)")
                #expect(visible.width * zoom >= min(64, view.width * zoom) - 1e-9 && visible.height * zoom >= min(64, view.height * zoom) - 1e-9, "zoom=\(zoom) far=\(far) visible=\(visible)")
            }
        }
        // 範囲の中の動きは、そのまま
        #expect(Viewport(zoom: 1, origin: CGPoint(x: 10, y: -10)).clamped(viewSize: view).origin == CGPoint(x: 10, y: -10))
    }

    @Test("見えている範囲：大きさは、画面の大きさ ÷ 倍率")
    func visibleRect() {
        let r = Viewport(zoom: 2, origin: CGPoint(x: 10, y: 20)).visibleRect(viewSize: view)
        #expect(r == CGRect(x: 10, y: 20, width: 240, height: 160))
        #expect(Viewport(zoom: 2, origin: .zero).scale == 0.5)
    }
}

@Suite("ビューの移動と拡大縮小：キャンバス（A35）")
@MainActor
struct ViewportCanvasTests {
    private func canvas() -> CanvasView { CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320)) }

    /// ウィンドウの座標の点 `w` で、マウスのイベントを作る（`bounds` の拡大縮小・移動を、`convert` が、キャンバスの座標にする）。
    private func mouse(_ type: NSEvent.EventType, _ w: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("拡大したまま描く：ポインタの位置が、キャンバスの座標に直って、ペンの点になる。キャンバス（書き出し）の大きさは、変わらない")
    func drawingWhileZoomed() throws {
        let c = canvas()
        let anchor = CGPoint(x: 240, y: 160)
        let w = c.convert(anchor, to: nil)
        c.zoomViewport(by: 2, at: anchor)
        #expect(c.viewport.zoom == 2)
        #expect(c.canvasRect == CGRect(x: 0, y: 0, width: 480, height: 320) && c.canvasSize == CGSize(width: 480, height: 320))
        #expect(abs(c.convert(w, from: nil).x - anchor.x) < 1e-9 && abs(c.convert(w, from: nil).y - anchor.y) < 1e-9)   // anchor は、画面の同じ位置
        c.tool = .pen
        let w2 = CGPoint(x: w.x + 100, y: w.y)   // 画面で右へ 100 pt ＝ キャンバスで右へ 50 pt
        c.mouseDown(with: try mouse(.leftMouseDown, w))
        c.mouseDragged(with: try mouse(.leftMouseDragged, w2))
        c.mouseUp(with: try mouse(.leftMouseUp, w2))
        guard case .pen(let points) = c.document.items.first?.content else { Issue.record("ペンの線がない"); return }
        #expect(abs(points[0].point.x - 240) < 1e-9 && abs(points[1].point.x - 290) < 1e-9)
        let png = try #require(c.renderPNG())
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 960 && rep.pixelsHigh == 640)   // 書き出しは、ビューに左右されない
    }

    @Test("ハンドツール：ドラッグで、ビューが、ポインタについて動く。描いたもの・履歴は、変わらない。離すと止まる")
    func handTool() throws {
        let c = canvas()
        c.tool = .pen
        c.mouseDown(with: try mouse(.leftMouseDown, c.convert(CGPoint(x: 50, y: 50), to: nil)))
        c.mouseDragged(with: try mouse(.leftMouseDragged, c.convert(CGPoint(x: 120, y: 80), to: nil)))
        c.mouseUp(with: try mouse(.leftMouseUp, c.convert(CGPoint(x: 120, y: 80), to: nil)))
        let before = c.document.items.count
        c.tool = .hand
        let start = CGPoint(x: 200, y: 200)   // ウィンドウの座標（上が正）
        c.mouseDown(with: try mouse(.leftMouseDown, start))
        c.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 230, y: 170)))   // 右へ 30、画面で下へ 30（ウィンドウの座標では、y が 30 減る）
        #expect(c.viewport.origin == CGPoint(x: -30, y: -30))                          // 内容が、右・下へ動く ＝ 見えている範囲は、左・上へ
        c.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 260, y: 140)))
        #expect(c.viewport.origin == CGPoint(x: -60, y: -60))                          // 始めの位置からの差で決まる
        c.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 260, y: 140)))
        #expect(c.document.items.count == before)
        c.undo()
        #expect(c.document.items.isEmpty)                                              // 取り消しは、ペンの線（ビューの動きは、段にならない）
        #expect(c.viewport.origin == CGPoint(x: -60, y: -60))
        c.resetViewport()
        #expect(c.viewport == .identity && c.bounds == NSRect(x: 0, y: 0, width: 480, height: 320))
    }

    @Test("ウィンドウの大きさが変わっても、倍率と見えている範囲の左上は、保たれる（キャンバスは、新しい大きさ）")
    func resizeKeepsTheView() {
        let c = canvas()
        c.zoomViewport(by: 2, at: .zero)
        c.panViewport(byScreen: CGSize(width: -40, height: -40))   // origin = (20, 20)
        let before = c.viewport
        c.setFrameSize(NSSize(width: 600, height: 400))
        #expect(c.viewport == before)
        #expect(c.canvasRect == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(c.bounds.size == CGSize(width: 300, height: 200) && c.bounds.origin == before.origin)
    }

    @Test("移動ツール：拡大縮小したままでも、取っ手は、画面での大きさで掴める（大きく縮小しても、小さくならない）")
    func handleGrabIsScreenSized() {
        let shape = ItemHandles.Shape.box(CGRect(x: 100, y: 100, width: 100, height: 80), rotation: 0)
        let corner = CGPoint(x: 200, y: 180)
        // 画面の 7 pt（掴める範囲の半分）は、25% のとき、キャンバスで 28 pt。等倍では、7 pt
        #expect(ItemHandles.handle(at: CGPoint(x: corner.x + 20, y: corner.y), in: shape, canvas: CGRect(x: 0, y: 0, width: 480, height: 320), scale: 4) == .corner(.bottomRight))
        #expect(ItemHandles.handle(at: CGPoint(x: corner.x + 20, y: corner.y), in: shape, canvas: CGRect(x: 0, y: 0, width: 480, height: 320), scale: 1) == nil)
        // 回転の取っ手も、画面で 24 pt 上
        let near = ItemHandles.rotationHandle(of: shape, canvas: CGRect(x: 0, y: 0, width: 480, height: 320), scale: 1).handle
        let far = ItemHandles.rotationHandle(of: shape, canvas: CGRect(x: 0, y: 0, width: 480, height: 320), scale: 2).handle
        #expect(abs((100 - near.y) - 24) < 1e-9 && abs((100 - far.y) - 48) < 1e-9)
    }

    @Test("Cmd+スクロールで拡大縮小、Cmd なしのスクロールで移動")
    func scrollWheel() throws {
        let c = canvas()
        func scroll(dy: Int32, command: Bool) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0))
            if command { cg.flags = .maskCommand }
            return try #require(NSEvent(cgEvent: cg))
        }
        c.scrollWheel(with: try scroll(dy: 100, command: true))
        #expect(c.viewport.zoom > 1)
        c.resetViewport()
        c.scrollWheel(with: try scroll(dy: 20, command: false))
        #expect(c.viewport.zoom == 1 && c.viewport.origin == CGPoint(x: 0, y: -20))   // 内容が下へ 20 pt ＝ 見えている範囲の左上は、上へ 20 pt
        c.resetViewport()
        c.scrollWheel(with: try scroll(dy: -100, command: true))
        #expect(c.viewport.zoom < 1)
    }
}

@Suite("ビューの移動と拡大縮小：レビューの指摘")
@MainActor
struct ViewportReviewTests {
    private func canvas() -> CanvasView { CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320)) }

    private func mouse(_ type: NSEvent.EventType, _ w: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("書き出し（renderPNG。キャッシュを通らない）は、ビューに左右されない：等倍と、拡大・移動したときで、同じバイト列")
    func exportIgnoresTheView() throws {
        let c = canvas()
        let black = CGColor(gray: 0, alpha: 1)
        c.appendFromAgent([
            Item(content: .rect(CGRect(x: 40, y: 40, width: 120, height: 80)), color: black, size: 6),
            Item(content: .triangle(CGRect(x: 200, y: 60, width: 100, height: 90)), color: black, size: 4, filled: true),
            Item(content: .line(from: CGPoint(x: 10, y: 250), to: CGPoint(x: 460, y: 300)), color: black, size: 3),
        ])
        let normal = try #require(c.renderPNG())
        c.zoomViewport(by: 3, at: CGPoint(x: 100, y: 100))
        c.panViewport(byScreen: CGSize(width: 70, height: -40))
        #expect(!c.viewport.isIdentity)
        #expect(c.renderPNG() == normal)
        c.zoomViewport(by: 0.1, at: CGPoint(x: 0, y: 0))
        #expect(c.renderPNG() == normal)
        #expect(c.renderCommittedPNG() == normal)
    }

    @Test("ドロップした位置は、キャンバスの縁に丸める（縮小・移動で出る、暗い外側へ落としても、画像が、キャンバスの外へ置かれない）")
    func dropLocationIsClamped() {
        let c = canvas()
        c.zoomViewport(by: 0.25, at: .zero)                        // 25%：キャンバスの外が、広く見える
        let farRight = c.convert(CGPoint(x: 1600, y: 640), to: nil)  // キャンバスの座標で、キャンバスの外
        let p = c.dropLocation(farRight)
        #expect(p == CGPoint(x: 480, y: 320))   // 縁（右下の角）に丸まる
        c.resetViewport()
        #expect(c.dropLocation(c.convert(CGPoint(x: 100, y: 50), to: nil)) == CGPoint(x: 100, y: 50))
    }

    @Test("ハンドのドラッグで、離す操作が届かなくても、次のドラッグが、パンにならない。パンの途中で、ツールを替えても、パンは止まる")
    func stalePanIsDropped() throws {
        let c = canvas()
        c.tool = .hand
        c.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))      // 離す操作は、来ない
        c.tool = .pen                                                                // ツールを替える：パンは止まる
        c.mouseDown(with: try mouse(.leftMouseDown, c.convert(CGPoint(x: 50, y: 50), to: nil)))
        c.mouseDragged(with: try mouse(.leftMouseDragged, c.convert(CGPoint(x: 120, y: 90), to: nil)))
        c.mouseUp(with: try mouse(.leftMouseUp, c.convert(CGPoint(x: 120, y: 90), to: nil)))
        #expect(c.viewport == .identity && c.document.items.count == 1)
        // ツールを替えないままでも、次の mouseDown が、古いパンを捨てる
        c.tool = .hand
        c.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        c.tool = .hand
        c.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        c.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 110, y: 100)))
        #expect(c.viewport.origin == CGPoint(x: -10, y: 0))                          // 2 回目の mouseDown が、基準
    }

    @Test("ハンドのドラッグの途中の、スクロール（と、ピンチ）は、受け付けない（ドラッグの基準が、ずれて、ビューが跳ばない）")
    func gesturesAreIgnoredWhilePanning() throws {
        let c = canvas()
        c.tool = .hand
        c.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 50, wheel2: 0, wheel3: 0))
        cg.flags = .maskCommand
        c.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        #expect(c.viewport == .identity)
        c.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 100, y: 100)))
        c.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        #expect(c.viewport.zoom > 1)                                                  // 離したあとは、効く
    }
}
