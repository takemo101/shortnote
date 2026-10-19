import AppKit
import Testing
@testable import ShortNoteKit

@Suite("手書きの形の整形：キャンバス（A37）")
@MainActor
struct ShapeSnapCanvasTests {
    private func canvas() -> CanvasView {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.tool = .pen
        c.color = .red
        c.brushSize = 6
        return c
    }

    private func mouse(_ type: NSEvent.EventType, _ c: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: c.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// 円を描く（ボタンを押して、動かして、押したままにする。離さない）。
    private func drawCircle(_ c: CanvasView, center: CGPoint = CGPoint(x: 240, y: 160), radius: CGFloat = 60) throws -> CGPoint {
        let points = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40 * 2 * .pi * 1.03
            return CGPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
        c.mouseDown(with: try mouse(.leftMouseDown, c, points[0]))
        for p in points.dropFirst() { c.mouseDragged(with: try mouse(.leftMouseDragged, c, p)) }
        return points.last!
    }

    @Test("円を描いて止める（待ち時間がたつ）と、楕円に置き替わる。離すと、確定する（ペンの線ではない）。色・太さは、ペンのまま。取り消すと、描く前に戻る")
    func snapsAndCommits() throws {
        let c = canvas()
        let last = try drawCircle(c)
        c.snapHeldStroke()
        c.mouseUp(with: try mouse(.leftMouseUp, c, last))
        #expect(c.document.items.count == 1)
        let item = c.document.items[0]
        guard case .ellipse(let rect) = item.content else { Issue.record("楕円でない：\(item.content)"); return }
        #expect(abs(rect.midX - 240) < 6 && abs(rect.midY - 160) < 6 && abs(rect.width - 120) < 10)
        #expect(item.size == 6 && !item.filled && item.color == NSColor.red.cgColor)
        c.undo()
        #expect(c.document.items.isEmpty)
    }

    @Test("止めずに離した線は、ペンの線のまま。どれにも見えない線は、止めても、置き替わらず、描き続けられる")
    func staysAPenStroke() throws {
        let c = canvas()
        let last = try drawCircle(c)
        c.mouseUp(with: try mouse(.leftMouseUp, c, last))                    // 止めずに離した
        guard case .pen = c.document.items[0].content else { Issue.record("ペンの線でない"); return }
        c.snapHeldStroke()                                                    // 離したあとの、待ちの発火は、何もしない
        #expect(c.document.items.count == 1)

        let d = canvas()
        let zig = [CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 150), CGPoint(x: 130, y: 50), CGPoint(x: 170, y: 150), CGPoint(x: 210, y: 50)]
        d.mouseDown(with: try mouse(.leftMouseDown, d, zig[0]))
        for p in zig.dropFirst() { d.mouseDragged(with: try mouse(.leftMouseDragged, d, p)) }
        d.snapHeldStroke()                                                    // 見えない：何も起きない
        d.mouseDragged(with: try mouse(.leftMouseDragged, d, CGPoint(x: 250, y: 150)))   // 描き続けられる
        d.mouseUp(with: try mouse(.leftMouseUp, d, CGPoint(x: 250, y: 150)))
        guard case .pen(let points) = d.document.items[0].content else { Issue.record("ペンの線でない"); return }
        #expect(points.count == 6 && points.last?.point == CGPoint(x: 250, y: 150))
    }

    @Test("置き替わったあと、押したまま動かすと、図形が回る（中心の周りに、ポインタの向きの変化の分だけ）。直線は、始点を軸に、終点が回る")
    func rotatesAfterSnapping() throws {
        let c = canvas()
        let last = try drawCircle(c, center: CGPoint(x: 240, y: 160), radius: 60)   // 始点は、右（240+60, 160）。止めた位置も、ほぼ右
        // 楕円ではなく、四角で確かめる（回転が見える）：四角を描いて、止めて、回す
        c.mouseUp(with: try mouse(.leftMouseUp, c, last))
        c.undo()
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 220), CGPoint(x: 100, y: 220), CGPoint(x: 100, y: 112)]
        var pts: [CGPoint] = []
        for i in 0..<(corners.count - 1) { for k in 0..<20 { let t = CGFloat(k) / 20; pts.append(CGPoint(x: corners[i].x + (corners[i + 1].x - corners[i].x) * t, y: corners[i].y + (corners[i + 1].y - corners[i].y) * t)) } }
        pts.append(corners.last!)
        c.mouseDown(with: try mouse(.leftMouseDown, c, pts[0]))
        for p in pts.dropFirst() { c.mouseDragged(with: try mouse(.leftMouseDragged, c, p)) }
        c.snapHeldStroke()
        // 中心 (200,160)。止めた位置 (100,112) は、中心から左上。ポインタを、中心の真上 (200,60) へ回す：向きは、左上（約 −154°）から真上（−90°）へ、約 +64°
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 200, y: 60)))
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 200, y: 60)))
        #expect(c.document.items.count == 1)
        guard case .rect(let rect) = c.document.items[0].content else { Issue.record("四角でない"); return }
        let expected = ItemHandles.angle(from: CGPoint(x: 200, y: 160), to: CGPoint(x: 200, y: 60)) - ItemHandles.angle(from: CGPoint(x: 200, y: 160), to: CGPoint(x: 100, y: 112))
        #expect(abs(ItemHandles.normalized(c.document.items[0].rotation - expected)) < 0.12, "rotation=\(c.document.items[0].rotation * 180 / .pi)° expected≈\(expected * 180 / .pi)°")
        #expect(abs(rect.midX - 200) < 8 && abs(rect.midY - 160) < 8)           // 中心は、動かない

        // 直線：始点を軸に、終点が回り、長さは、ポインタの距離の比（240 → 180）で変わる
        let d = canvas()
        d.mouseDown(with: try mouse(.leftMouseDown, d, CGPoint(x: 60, y: 200)))
        for i in 1...30 { d.mouseDragged(with: try mouse(.leftMouseDragged, d, CGPoint(x: 60 + CGFloat(i) * 8, y: 200))) }
        d.snapHeldStroke()
        d.mouseDragged(with: try mouse(.leftMouseDragged, d, CGPoint(x: 60, y: 20)))   // 始点の真上へ（終点 (300,200) の向き：右 → 上へ、-90°）。距離 180
        d.mouseUp(with: try mouse(.leftMouseUp, d, CGPoint(x: 60, y: 20)))
        guard case .line(let from, let to) = d.document.items[0].content else { Issue.record("直線でない：\(d.document.items[0].content)"); return }
        #expect(abs(from.x - 60) < 1.5 && abs(from.y - 200) < 1.5)
        #expect(abs(to.x - 60) < 6 && abs(hypot(to.x - from.x, to.y - from.y) - 180) < 6 && to.y < from.y)   // 真上へ、長さは 180
    }

    @Test("矢印：整形すると、終点に矢じりのある直線になる")
    func arrowSnaps() throws {
        let c = canvas()
        var pts: [CGPoint] = (0...25).map { CGPoint(x: 50 + CGFloat($0) * 10, y: 200) }
        pts += (1...6).map { CGPoint(x: 300 - CGFloat($0) * 4.5, y: 200 - CGFloat($0) * 3) }   // 上へ折り返す
        pts += (1...6).map { CGPoint(x: 273 + CGFloat($0) * 4.5, y: 182 + CGFloat($0) * 3) }    // 先へ戻る
        pts += (1...6).map { CGPoint(x: 300 - CGFloat($0) * 4.5, y: 200 + CGFloat($0) * 3) }    // 下へ折り返す
        c.mouseDown(with: try mouse(.leftMouseDown, c, pts[0]))
        for p in pts.dropFirst() { c.mouseDragged(with: try mouse(.leftMouseDragged, c, p)) }
        c.snapHeldStroke()
        c.mouseUp(with: try mouse(.leftMouseUp, c, pts.last!))
        guard case .line(let from, let to) = c.document.items[0].content else { Issue.record("直線でない"); return }
        #expect(c.document.items[0].arrow == .end && abs(from.x - 50) < 4 && abs(to.x - 300) < 8)
    }

    @Test("ペン以外のツールでは、働かない。ツールを替えると、待ちは止まる")
    func onlyForThePen() throws {
        let c = canvas()
        c.tool = .line
        c.mouseDown(with: try mouse(.leftMouseDown, c, CGPoint(x: 50, y: 50)))
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 200, y: 50)))
        c.snapHeldStroke()
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 200, y: 50)))
        guard case .line = c.document.items[0].content else { Issue.record("直線でない"); return }
        #expect(c.document.items[0].arrow == .none)
        // ペンで描いている途中に、ツールを替えて、待ちが発火しても、置き替わらない
        let d = canvas()
        let last = try drawCircle(d)
        d.tool = .move
        d.snapHeldStroke()
        d.mouseUp(with: try mouse(.leftMouseUp, d, last))
        if case .ellipse? = d.document.items.first?.content { Issue.record("ツールを替えたのに、整形された") }
    }
}

@Suite("手書きの形の整形：レビューの指摘（A37）")
@MainActor
struct ShapeSnapReviewTests {
    private func canvas() -> CanvasView {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.tool = .pen
        return c
    }

    private func mouse(_ type: NSEvent.EventType, _ c: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: c.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// 直線を描き、そのあと、止めている間の手の震え（基準から 3 pt 以内）の点を、足す。
    private func lineWithTrembling(_ c: CanvasView, length: CGFloat = 200, jitter: CGFloat = 1.5) throws -> CGPoint {
        let start = CGPoint(x: 60, y: 200)
        c.mouseDown(with: try mouse(.leftMouseDown, c, start))
        for i in 1...40 { c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: start.x + length * CGFloat(i) / 40, y: start.y))) }
        let end = CGPoint(x: start.x + length, y: start.y)
        for i in 0..<20 {   // 震え（基準の点から 1.5 pt 以内）
            let dx = (i % 2 == 0 ? jitter : -jitter), dy = (i % 3 == 0 ? jitter : -jitter)
            c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: end.x + dx, y: end.y + dy)))
        }
        return end
    }

    @Test("止めている間の手の震えの点（基準から 3 pt 以内）があっても、直線に整形される（震えの点は、判定から外す）")
    func tremblingDoesNotPreventALine() throws {
        let c = canvas()
        let end = try lineWithTrembling(c)
        c.snapHeldStroke()
        c.mouseUp(with: try mouse(.leftMouseUp, c, end))
        guard case .line(let from, let to) = c.document.items.first?.content else { Issue.record("直線にならない：\(String(describing: c.document.items.first?.content))"); return }
        #expect(abs(to.x - 260) < 4 && abs(from.x - 60) < 4)
    }

    @Test("実際のタイマーで整形される（0.6 秒）。動き続けている間は、整形されない")
    func realTimer() throws {
        let c = canvas()
        let start = CGPoint(x: 60, y: 200)
        c.mouseDown(with: try mouse(.leftMouseDown, c, start))
        for i in 1...40 { c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: start.x + 5 * CGFloat(i), y: start.y))) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))                      // まだ待ち時間の前
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 260, y: 200)))
        guard case .pen = c.document.items[0].content else { Issue.record("早すぎる整形"); return }

        let d = canvas()
        d.mouseDown(with: try mouse(.leftMouseDown, d, start))
        for i in 1...40 { d.mouseDragged(with: try mouse(.leftMouseDragged, d, CGPoint(x: start.x + 5 * CGFloat(i), y: start.y))) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))                       // 待ち時間を超える（動いていない）
        d.mouseUp(with: try mouse(.leftMouseUp, d, CGPoint(x: 260, y: 200)))
        guard case .line = d.document.items[0].content else { Issue.record("タイマーで整形されない：\(d.document.items[0].content)"); return }
    }

    @Test("キャンバスの外で、動かし続けているとき（0.1 秒ごとに、画面で 30 pt）は、止まったとみなさない（縁に丸めた位置は、同じでも、実際の位置で比べる）")
    func movingOutsideTheCanvasIsNotHolding() throws {
        let c = canvas()
        c.mouseDown(with: try mouse(.leftMouseDown, c, CGPoint(x: 60, y: 200)))
        for i in 1...30 { c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 60 + CGFloat(i) * 7, y: 200))) }   // x=270
        for i in 0..<9 {   // 縁（480）の外を、0.9 秒、動かし続ける：縁に丸めた位置は、ずっと (480,200)
            c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 600 + CGFloat(i) * 30, y: 200)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 840, y: 200)))
        guard case .pen = c.document.items[0].content else { Issue.record("動かし続けているのに、整形された：\(c.document.items[0].content)"); return }
    }

    @Test("整形した図形を回している途中で、ツールを替えると、その図形は捨てられ、崩れた図形が残らない")
    func toolSwitchWhileRotating() throws {
        let c = canvas()
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 220), CGPoint(x: 100, y: 220), CGPoint(x: 100, y: 112)]
        var pts: [CGPoint] = []
        for i in 0..<4 { for k in 0..<20 { let t = CGFloat(k) / 20; pts.append(CGPoint(x: corners[i].x + (corners[i + 1].x - corners[i].x) * t, y: corners[i].y + (corners[i + 1].y - corners[i].y) * t)) } }
        c.mouseDown(with: try mouse(.leftMouseDown, c, pts[0]))
        for p in pts.dropFirst() { c.mouseDragged(with: try mouse(.leftMouseDragged, c, p)) }
        c.snapHeldStroke()
        c.tool = .rect
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 350, y: 300)))
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 350, y: 300)))
        #expect(c.document.items.isEmpty)
    }

    @Test("回しているとき、掴める範囲が、キャンバスの中にほとんど残らなくなる向きへは、回さない（移動ツールの回転と同じ規則）")
    func rotationKeepsTheShapeReachable() throws {
        let c = canvas()
        // 左の縁の近く (12,160) から、右へ 240 pt の直線。始点が軸。真左へ回すと、終点が、キャンバスの外へ出て、掴める範囲が、ほとんど残らない
        let start = CGPoint(x: 12, y: 160)
        c.mouseDown(with: try mouse(.leftMouseDown, c, start))
        for i in 1...40 { c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: start.x + 6 * CGFloat(i), y: start.y))) }
        c.snapHeldStroke()
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 0, y: 160)))      // 始点の真左（縁）
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 0, y: 160)))
        guard case .line(let from, let to) = c.document.items[0].content else { Issue.record("直線でない"); return }
        let item = c.document.items[0]
        let visible = item.bounds.insetBy(dx: -4, dy: -4).intersection(c.canvasRect)
        #expect(!visible.isNull && visible.width >= 16 - 1e-9, "from=\(from) to=\(to) visible=\(visible)")
    }
}
