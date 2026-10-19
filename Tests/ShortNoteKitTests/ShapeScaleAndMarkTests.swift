import AppKit
import Testing
@testable import ShortNoteKit

@Suite("整形した図形の拡大縮小（A37）")
struct RecognizedShapeTransformTests {
    @Test("直線・矢印：始点を軸に、終点が回り、長さが倍率の分だけ変わる")
    func lineAndArrow() {
        guard case .line(let from, let to) = RecognizedShape.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 10)).transformed(by: .pi / 2, scale: 2) else { Issue.record("直線でない"); return }
        #expect(from == CGPoint(x: 10, y: 10))
        #expect(abs(to.x - 10) < 1e-9 && abs(to.y - 210) < 1e-9)   // 時計回りに 90°（下向き）、長さ 200
        guard case .arrow(_, let tip) = RecognizedShape.arrow(from: .zero, to: CGPoint(x: 30, y: 0)).transformed(by: 0, scale: 0.5) else { Issue.record("矢印でない"); return }
        #expect(tip == CGPoint(x: 15, y: 0))
    }

    @Test("円・四角・三角：中心を保ち、相似に拡大縮小し、回転が加わる（縦横の比は、そのまま）")
    func boxes() {
        let rect = CGRect(x: 100, y: 50, width: 80, height: 40)
        for shape in [RecognizedShape.ellipse(rect: rect, rotation: 0.1), .rect(rect: rect, rotation: 0.1), .triangle(rect: rect, rotation: 0.1)] {
            let result: (CGRect, CGFloat)
            switch shape.transformed(by: 0.3, scale: 1.5) {
            case .ellipse(let r, let a), .rect(let r, let a), .triangle(let r, let a): result = (r, a)
            default: Issue.record("種類が変わった"); continue
            }
            #expect(abs(result.0.midX - 140) < 1e-9 && abs(result.0.midY - 70) < 1e-9)
            #expect(abs(result.0.width - 120) < 1e-9 && abs(result.0.height - 60) < 1e-9)
            #expect(abs(result.1 - 0.4) < 1e-9)
        }
    }

    @Test("倍率の範囲：短い辺が 8 pt より小さくならず、10 倍より大きくならない。非有限は、そのまま（1 倍）")
    func limits() {
        let rect = RecognizedShape.rect(rect: CGRect(x: 0, y: 0, width: 100, height: 40), rotation: 0)
        guard case .rect(let small, _) = rect.transformed(by: 0, scale: 0.001) else { Issue.record("四角でない"); return }
        #expect(abs(small.height - 8) < 1e-9 && abs(small.width - 20) < 1e-9)
        guard case .rect(let big, _) = rect.transformed(by: 0, scale: 500) else { Issue.record("四角でない"); return }
        #expect(abs(big.width - 1000) < 1e-9)
        let line = RecognizedShape.line(from: .zero, to: CGPoint(x: 50, y: 0))
        guard case .line(_, let end) = line.transformed(by: 0, scale: 0.0001) else { Issue.record("直線でない"); return }
        #expect(abs(end.x - 8) < 1e-9)
        guard case .line(_, let same) = line.transformed(by: 0, scale: .nan) else { Issue.record("直線でない"); return }
        #expect(same == CGPoint(x: 50, y: 0))
        // もともと 8 pt より短い図形は、縮めない
        guard case .line(_, let tiny) = RecognizedShape.line(from: .zero, to: CGPoint(x: 5, y: 0)).transformed(by: 0, scale: 0.1) else { Issue.record("直線でない"); return }
        #expect(tiny == CGPoint(x: 5, y: 0))
    }
}

@Suite("待ち時間の印・拡大縮小・ビューの帯（A37・A38）")
@MainActor
struct ShapeScaleAndMarkTests {
    private func canvas() -> CanvasView {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.tool = .pen
        c.brushSize = 6
        return c
    }

    private func mouse(_ type: NSEvent.EventType, _ c: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: c.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drawCircle(_ c: CanvasView) throws -> CGPoint {
        let points = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40 * 2 * .pi * 1.03
            return CGPoint(x: 240 + 60 * cos(t), y: 160 + 60 * sin(t))
        }
        c.mouseDown(with: try mouse(.leftMouseDown, c, points[0]))
        for p in points.dropFirst() { c.mouseDragged(with: try mouse(.leftMouseDragged, c, p)) }
        return points.last!
    }

    @Test("整形したあと、軸からポインタまでの距離の比で、拡大縮小する。向きを変えれば、回る（同時）")
    func scalesAndRotatesWithThePointer() throws {
        let c = canvas()
        let last = try drawCircle(c)
        c.snapHeldStroke()
        let pivot = CGPoint(x: 240, y: 160)
        let v = CGPoint(x: last.x - pivot.x, y: last.y - pivot.y)
        // 距離 2 倍、向きは 90° 回す（時計回り。反転した座標で、(x,y) → (-y,x)）
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: pivot.x - 2 * v.y, y: pivot.y + 2 * v.x)))
        c.mouseUp(with: try mouse(.leftMouseUp, c, last))
        let item = c.document.items[0]
        guard case .ellipse(let rect) = item.content else { Issue.record("楕円でない：\(item.content)"); return }
        #expect(abs(rect.width - 240) < 20, "width=\(rect.width)")
        #expect(abs(abs(item.rotation) - .pi / 2) < 0.05, "rotation=\(item.rotation)")
    }

    @Test("縮める向きの限界：短い辺が 8 pt で止まる。直線は、始点を軸に、長さが距離の比で変わる")
    func scaleStopsAtTheLimit() throws {
        let c = canvas()
        let last = try drawCircle(c)
        c.snapHeldStroke()
        let pivot = CGPoint(x: 240, y: 160)
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: pivot.x + (last.x - pivot.x) * 0.03, y: pivot.y + (last.y - pivot.y) * 0.03)))
        c.mouseUp(with: try mouse(.leftMouseUp, c, last))
        guard case .ellipse(let rect) = c.document.items[0].content else { Issue.record("楕円でない"); return }
        #expect(abs(min(rect.width, rect.height) - 8) < 0.5, "size=\(rect.size)")

        let d = canvas()
        let start = CGPoint(x: 60, y: 200)
        d.mouseDown(with: try mouse(.leftMouseDown, d, start))
        for i in 1...40 { d.mouseDragged(with: try mouse(.leftMouseDragged, d, CGPoint(x: start.x + 5 * CGFloat(i), y: start.y))) }
        d.snapHeldStroke()
        d.mouseDragged(with: try mouse(.leftMouseDragged, d, CGPoint(x: 60 + 300, y: 200)))
        d.mouseUp(with: try mouse(.leftMouseUp, d, CGPoint(x: 360, y: 200)))
        guard case .line(let from, let to) = d.document.items[0].content else { Issue.record("直線でない"); return }
        #expect(from == start && abs(to.x - 360) < 1 && abs(to.y - 200) < 1, "to=\(to)")
    }

    @Test("待ち時間の印：円弧の伸びは、0.12 秒まで出ず、0.6 秒で 1 周")
    func markProgress() {
        #expect(CanvasView.holdMarkProgress(elapsed: 0.05) == nil)
        #expect(CanvasView.holdMarkProgress(elapsed: 0.12) == 0)
        #expect(abs((CanvasView.holdMarkProgress(elapsed: 0.36) ?? -1) - 0.5) < 1e-9)
        #expect(CanvasView.holdMarkProgress(elapsed: 0.6) == 1)
        #expect(CanvasView.holdMarkProgress(elapsed: 9) == 1)
    }

    @Test("待ち時間の印：押すと出て（止めた位置）、動くと、その位置から出し直す。整形すると閉じ、ポインタについてくる。離す・ツールを替える・ペン以外では、消える")
    func markLifecycle() throws {
        let c = canvas()
        c.mouseDown(with: try mouse(.leftMouseDown, c, CGPoint(x: 100, y: 100)))
        #expect(c.holdMark?.center == CGPoint(x: 100, y: 100) && c.holdMark?.snapped == false)
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 101, y: 100)))   // 3 pt 以内：位置は、そのまま
        #expect(c.holdMark?.center == CGPoint(x: 100, y: 100))
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 140, y: 100)))   // 動いた：出し直す
        #expect(c.holdMark?.center == CGPoint(x: 140, y: 100))
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 140, y: 100)))
        #expect(c.holdMark == nil)

        let d = canvas()
        let last = try drawCircle(d)
        d.snapHeldStroke()
        #expect(d.holdMark?.snapped == true)
        let moved = CGPoint(x: last.x + 20, y: last.y + 10)
        d.mouseDragged(with: try mouse(.leftMouseDragged, d, moved))
        #expect(d.holdMark?.center == moved && d.holdMark?.snapped == true)
        d.tool = .rect
        #expect(d.holdMark == nil)

        // 見えない線では、輪は消える（下の f）
        let f = canvas()
        f.mouseDown(with: try mouse(.leftMouseDown, f, CGPoint(x: 50, y: 50)))
        for p in [CGPoint(x: 90, y: 150), CGPoint(x: 130, y: 50), CGPoint(x: 170, y: 150)] { f.mouseDragged(with: try mouse(.leftMouseDragged, f, p)) }
        f.snapHeldStroke()
        #expect(f.holdMark == nil)

        let g = canvas()
        g.tool = .rect
        g.mouseDown(with: try mouse(.leftMouseDown, g, CGPoint(x: 50, y: 50)))
        #expect(g.holdMark == nil)
    }

    @Test("ビューの変化が、通知される。倍率だけを 100% に戻すと、見えている範囲の中心は、動かない。戻すと、等倍・移動なし")
    func viewportCallbackAndResets() throws {
        let c = canvas()
        var seen: [Viewport] = []
        c.onViewportChange = { seen.append($0) }
        c.zoomViewport(by: 2, at: CGPoint(x: 240, y: 160))
        c.panViewport(byScreen: CGSize(width: 30, height: -20))
        #expect(seen.count == 2 && seen[0].zoom == 2)
        let before = c.viewport.visibleRect(viewSize: c.canvasSize)
        c.resetZoom()
        let after = c.viewport.visibleRect(viewSize: c.canvasSize)
        #expect(c.viewport.zoom == 1)
        #expect(abs(before.midX - after.midX) < 1e-6 && abs(before.midY - after.midY) < 1e-6)
        c.resetViewport()
        #expect(c.viewport.isIdentity && seen.last?.isIdentity == true)
    }

    @Test("ビューの帯：等倍・移動なしなら隠れ、そうでなければ倍率（整数の %）を出す。倍率を押す・戻すボタンを押すと、それぞれ通知する")
    func viewControls() {
        let bar = ViewControlsView(frame: .zero)
        #expect(bar.isHidden)
        bar.show(Viewport(zoom: 1.25, origin: .zero))
        #expect(!bar.isHidden && bar.zoomButton.title == "125%")
        bar.show(Viewport(zoom: 1, origin: CGPoint(x: 40, y: 0)))                    // 動かしただけ：100% で出る
        #expect(!bar.isHidden && bar.zoomButton.title == "100%")
        bar.show(.identity)
        #expect(bar.isHidden)
        #expect(ViewControlsView.zoomText(0.333) == "33%" && ViewControlsView.zoomText(4) == "400%")
        var zoomReset = 0, viewReset = 0
        bar.onResetZoom = { zoomReset += 1 }
        bar.onResetView = { viewReset += 1 }
        bar.zoomButton.performClick(nil)
        bar.resetButton.performClick(nil)
        bar.resetButton.performClick(nil)
        #expect(zoomReset == 1 && viewReset == 2)
    }

    @Test("倍率を 100% に戻すと、倍率が、ちょうど 1 になる（誤差が残らない）。どの倍率からでも")
    func resetZoomIsExact() {
        let size = CGSize(width: 480, height: 320)
        for z in stride(from: 0.26, through: 3.99, by: 0.01) {
            let viewport = Viewport(zoom: CGFloat(z), origin: CGPoint(x: 20, y: 10)).clamped(viewSize: size)
            let reset = viewport.resetZoom(centeredOn: CGPoint(x: 240, y: 160), viewSize: size)
            #expect(reset.zoom == 1, "zoom \(z) → \(reset.zoom)")
        }
        let c = canvas()
        c.zoomViewport(by: 0.36, at: CGPoint(x: 240, y: 160))
        c.resetZoom()
        #expect(c.viewport.zoom == 1)
    }

    @Test("縮小して、キャンバスの外が、見えている範囲の中心になったあと、100% に戻しても、キャンバスが、画面の隅に、わずかしか残らない形にならない")
    func resetZoomKeepsTheCanvasInView() {
        let c = canvas()
        c.zoomViewport(by: 0.25, at: CGPoint(x: 0, y: 0))     // 25%（左上を止めて縮小：見えている範囲の中心は、キャンバスの外の右下）
        c.resetZoom()
        let visible = c.viewport.visibleRect(viewSize: c.canvasSize).intersection(c.canvasRect)
        #expect(c.viewport.zoom == 1 && visible.width >= 200 && visible.height >= 130, "visible=\(visible)")
    }

    @Test("ビューの帯の背景・縁の色は、見た目（ダーク）が変わると、作り直される")
    func barColoursFollowTheAppearance() throws {
        let bar = ViewControlsView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        func background(_ appearance: NSAppearance.Name) throws -> CGColor {
            bar.appearance = try #require(NSAppearance(named: appearance))
            bar.effectiveAppearance.performAsCurrentDrawingAppearance { bar.updateLayer() }
            return try #require(bar.layer?.backgroundColor)
        }
        let light = try background(.aqua), dark = try background(.darkAqua)
        #expect(light != dark)
    }
}
