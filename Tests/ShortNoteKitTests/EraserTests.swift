import AppKit
import Testing
@testable import ShortNoteKit

private let black = CGColor(gray: 0, alpha: 1)

private func pen(_ pts: [(CGFloat, CGFloat)], size: CGFloat = 4) -> Item {
    Item(content: .pen(points: pts.map { StrokePoint(point: CGPoint(x: $0.0, y: $0.1), pressure: 1) }), color: black, size: size)
}

@Suite("消しゴム：当たり判定（A36）")
struct EraserHitTests {
    private let r: CGFloat = 8
    private func touched(_ item: Item, _ a: CGPoint, _ b: CGPoint? = nil) -> Bool { item.isTouched(from: a, to: b ?? a, radius: r) }

    @Test("ペン：線の近くに触れたら当たり、離れていれば外れる。点と点の間を、横切った動きも当たり")
    func penStroke() {
        let stroke = pen([(100, 100), (200, 100), (200, 200)])
        #expect(touched(stroke, CGPoint(x: 150, y: 105)))
        #expect(touched(stroke, CGPoint(x: 150, y: 100 - r - 2 + 1)))           // 半径＋線の太さの半分（2）の内側
        #expect(!touched(stroke, CGPoint(x: 150, y: 100 - r - 2 - 1)))          // すぐ外
        #expect(touched(stroke, CGPoint(x: 150, y: 50), CGPoint(x: 150, y: 150)))   // 速く動かして、サンプルの間で、線を横切った
        #expect(!touched(stroke, CGPoint(x: 150, y: 150)))
        #expect(touched(pen([(50, 50)]), CGPoint(x: 54, y: 50)))                // 点 1 つのペン
    }

    @Test("直線：線の近く。矢じりの先も当たり")
    func lineAndArrowhead() {
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 300, y: 100)
        let plain = Item(content: .line(from: a, to: b), color: black, size: 10)
        let arrow = Item(content: .line(from: a, to: b), color: black, size: 10, arrow: .end)
        #expect(touched(plain, CGPoint(x: 200, y: 108)) && !touched(plain, CGPoint(x: 200, y: 130)))
        // 太さ 10 の矢じり：長さ 35、腕の先は、線から約 16 pt 離れる。腕の先は、普通の線の（半径 8＋太さの半分 5）の外
        let head = Arrowhead.segments(from: a, to: b, size: 10, arrow: .end)
        #expect(head.count == 2)
        let armEnd = head[0].end
        #expect(abs(armEnd.y - 100) > r + 5 + 1)                                  // 前提：普通の線の判定の外
        #expect(!touched(plain, armEnd) && touched(arrow, armEnd))                // 矢じりがあると、当たる
    }

    @Test("四角（枠だけ）：辺の近くは当たり。内側の空白は外れる。塗りつぶしは、内側も当たり")
    func rect() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 120)
        let outline = Item(content: .rect(box), color: black, size: 4)
        let filled = Item(content: .rect(box), color: black, size: 4, filled: true)
        #expect(touched(outline, CGPoint(x: 100, y: 160)) && touched(outline, CGPoint(x: 200, y: 222)))
        #expect(!touched(outline, CGPoint(x: 200, y: 160)))                      // 内側の空白
        #expect(!touched(outline, CGPoint(x: 50, y: 160)))                       // 外
        #expect(touched(filled, CGPoint(x: 200, y: 160)))
        #expect(touched(outline, CGPoint(x: 200, y: 160), CGPoint(x: 200, y: 400)))   // 内側から出て、下の辺を横切る
    }

    @Test("円：外接する四角の角（円の外）は、外れる。円周の近くは当たり。塗りは、内側も")
    func ellipse() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 200)
        let outline = Item(content: .ellipse(box), color: black, size: 4)
        #expect(touched(outline, CGPoint(x: 100, y: 200)) && touched(outline, CGPoint(x: 200, y: 100)))
        #expect(!touched(outline, CGPoint(x: 105, y: 105)))                      // 四角の角：円の外
        #expect(!touched(outline, CGPoint(x: 200, y: 200)))                      // 中心：空白
        #expect(touched(Item(content: .ellipse(box), color: black, size: 4, filled: true), CGPoint(x: 200, y: 200)))
    }

    @Test("三角：辺の近くは当たり、頂点の脇の空白（枠の上の隅）は外れる")
    func triangle() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 160)                // 頂点 (200,100)、底辺 y=260
        let outline = Item(content: .triangle(box), color: black, size: 4)
        #expect(touched(outline, CGPoint(x: 200, y: 103)) && touched(outline, CGPoint(x: 200, y: 262)))
        #expect(!touched(outline, CGPoint(x: 110, y: 110)))                      // 枠の左上の隅：三角形の外
        #expect(!touched(outline, CGPoint(x: 200, y: 200)))                      // 内側の空白
        #expect(touched(Item(content: .triangle(box), color: black, size: 4, filled: true), CGPoint(x: 200, y: 200)))
    }

    @Test("回した要素：回した向きの形で判定する（90° 回した横長の四角は、縦長になる。30° でも、向きが合う）")
    func rotated() {
        let box = CGRect(x: 100, y: 190, width: 200, height: 20)                 // 中心 (200,200)。90° 回すと、x=190〜210、y=100〜300
        let turned = Item(content: .rect(box), color: black, size: 2, filled: true, rotation: .pi / 2)
        #expect(touched(turned, CGPoint(x: 200, y: 110)) && touched(turned, CGPoint(x: 200, y: 290)))
        #expect(!touched(turned, CGPoint(x: 120, y: 200)))                       // 回す前の、左の端：いまは空白
        // 30°（時計回り。y が下向き）：右の端は、(200 + 90 cos30°, 200 + 90 sin30°) の側へ、下がる
        let tilted = Item(content: .rect(box), color: black, size: 2, filled: true, rotation: .pi / 6)
        let c = cos(CGFloat.pi / 6), s = sin(CGFloat.pi / 6)
        #expect(touched(tilted, CGPoint(x: 200 + 90 * c, y: 200 + 90 * s)))      // 右下へ下がった端
        #expect(!touched(tilted, CGPoint(x: 200 + 90 * c, y: 200 - 90 * s)))     // 逆向き（右上）には、無い
        #expect(!touched(tilted, CGPoint(x: 290, y: 200)))                       // 回す前の右の端：いまは、軸から 45 pt ずれている
    }

    @Test("ペンの筆圧：筆圧が弱いと、描かれる線は細い。当たり判定も、描かれる幅に合わせる（太さの最大値のままにしない）")
    func penPressure() {
        func stroke(_ pressure: CGFloat) -> Item {
            Item(content: .pen(points: [StrokePoint(point: CGPoint(x: 100, y: 100), pressure: pressure), StrokePoint(point: CGPoint(x: 300, y: 100), pressure: pressure)]), color: black, size: 40)
        }
        let probe = CGPoint(x: 200, y: 100 + r + 12)                             // 線から 20 pt
        #expect(touched(stroke(1), probe))                                       // 太さ 40 の全幅：半径 8 + 20 = 28
        #expect(!touched(stroke(0), probe))                                      // 筆圧 0：描かれる幅 10 → 半径 8 + 5 = 13
    }

    @Test("文字・画像：外接する枠の中（空白でも）は当たり。枠の外は外れる。回した枠は、回した向き")
    func textAndImage() {
        let text = Item(content: .text("Hello", box: CGRect(x: 100, y: 100, width: 80, height: 24)), color: black, size: 18)
        #expect(touched(text, CGPoint(x: 140, y: 112)) && !touched(text, CGPoint(x: 140, y: 140)))
        let turned = Item(content: .text("Hello", box: CGRect(x: 100, y: 100, width: 80, height: 24)), color: black, size: 18, rotation: .pi / 2)
        #expect(touched(turned, CGPoint(x: 140, y: 140)) && !touched(turned, CGPoint(x: 110, y: 112)))   // 中心 (140,112)。縦長になる
    }

    @Test("文書から消す：指定の要素だけ。範囲外の番号は除く。何も消えなければ nil。背景は残る")
    func removing() {
        let a = pen([(10, 10), (20, 20)]), b = pen([(30, 30), (40, 40)]), c = pen([(50, 50), (60, 60)])
        let doc = Document().appending(contentsOf: [a, b, c])
        let removed = doc.removingItems(at: [0, 2, 9])
        #expect(removed?.items.count == 1)
        if case .pen(let points)? = removed?.items.first?.content { #expect(points.first?.point == CGPoint(x: 30, y: 30)) } else { Issue.record("b が残らない") }
        #expect(doc.removingItems(at: []) == nil && doc.removingItems(at: [7]) == nil)
    }
}

@Suite("消しゴム：キャンバス（A36）")
@MainActor
struct EraserCanvasTests {
    private func canvas(_ items: [Item]) -> CanvasView {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.appendFromAgent(items)
        c.tool = .eraser
        return c
    }

    private func mouse(_ type: NSEvent.EventType, _ c: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: c.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(_ c: CanvasView, _ points: [CGPoint]) throws {
        c.mouseDown(with: try mouse(.leftMouseDown, c, points[0]))
        for p in points.dropFirst() { c.mouseDragged(with: try mouse(.leftMouseDragged, c, p)) }
        c.mouseUp(with: try mouse(.leftMouseUp, c, points.last!))
    }

    @Test("なぞった要素だけが、離したときに、まとめて消える（重なった要素も、すべて）。取り消し 1 回で、すべて戻る")
    func erasesWhatWasTouched() throws {
        let box = CGRect(x: 100, y: 100, width: 80, height: 60)
        let c = canvas([
            Item(content: .rect(box), color: black, size: 4),                                      // 0：なぞる
            Item(content: .rect(box.insetBy(dx: -2, dy: -2)), color: black, size: 4),              // 1：重なっている
            Item(content: .ellipse(CGRect(x: 300, y: 200, width: 80, height: 60)), color: black, size: 4),   // 2：触れない
        ])
        try drag(c, [CGPoint(x: 90, y: 130), CGPoint(x: 140, y: 130), CGPoint(x: 140, y: 175)])   // 左の辺を通って、下の辺を横切る
        #expect(c.document.items.count == 1)
        guard case .ellipse = c.document.items[0].content else { Issue.record("円が残らない"); return }
        c.undo()
        #expect(c.document.items.count == 3)
    }

    @Test("途中は、まだ消えない（薄く描くだけ）。何にも触れなかったドラッグは、取り消しの段にならない")
    func nothingTouched() throws {
        let c = canvas([Item(content: .rect(CGRect(x: 100, y: 100, width: 80, height: 60)), color: black, size: 4)])
        c.mouseDown(with: try mouse(.leftMouseDown, c, CGPoint(x: 100, y: 130)))
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 110, y: 130)))
        #expect(c.document.items.count == 1 && c.isInteracting)                  // 離すまで、消えない
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 110, y: 130)))
        #expect(c.document.items.isEmpty && !c.isInteracting)
        c.undo()
        #expect(c.document.items.count == 1)
        try drag(c, [CGPoint(x: 400, y: 300), CGPoint(x: 420, y: 300)])           // 何にも触れない
        c.undo()
        #expect(c.document.items.isEmpty)                                        // 1 回の取り消しで、描いた要素の追加が戻る（空のドラッグが、段を足していない）
    }

    @Test("ドラッグの途中で、ツールを替える・取り消す・クリアすると、何も消えない（残るべき要素が、残る）")
    func interruptions() throws {
        let a = Item(content: .rect(CGRect(x: 300, y: 40, width: 60, height: 40)), color: black, size: 4)
        let b = Item(content: .rect(CGRect(x: 100, y: 100, width: 80, height: 60)), color: black, size: 4)
        // ツールを替える：b の辺に触れて押したまま、ペンに替えて、また戻して、離す → a・b とも残る
        let t = canvas([a, b])
        t.mouseDown(with: try mouse(.leftMouseDown, t, CGPoint(x: 100, y: 130)))
        t.tool = .pen
        t.tool = .eraser
        t.mouseUp(with: try mouse(.leftMouseUp, t, CGPoint(x: 100, y: 130)))
        #expect(t.document.items.count == 2)
        // 取り消し：a・b を 2 段で足し、b の辺に触れて押したまま、取り消す（b が戻る＝a だけ残る）→ 離しても、a が消えない
        let u = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        u.appendFromAgent([a]); u.appendFromAgent([b])
        u.tool = .eraser
        u.mouseDown(with: try mouse(.leftMouseDown, u, CGPoint(x: 100, y: 130)))
        u.undo()
        #expect(u.document.items.count == 1)
        u.mouseUp(with: try mouse(.leftMouseUp, u, CGPoint(x: 100, y: 130)))
        #expect(u.document.items.count == 1)
        // クリア（エージェント）：b に触れて押したまま、全部消されて、新しい要素 a が足される → 離しても、a が消えない
        let w = canvas([b])
        w.mouseDown(with: try mouse(.leftMouseDown, w, CGPoint(x: 100, y: 130)))
        _ = w.clearFromAgent()
        w.appendFromAgent([a])
        w.mouseUp(with: try mouse(.leftMouseUp, w, CGPoint(x: 100, y: 130)))
        #expect(w.document.items.count == 1)
    }

    @Test("離す操作が届かなかったとき：印のついた要素は、次のドラッグで、消えない（次の mouseDown が、捨てる）")
    func staleMarksAreDropped() throws {
        let b = Item(content: .rect(CGRect(x: 100, y: 100, width: 80, height: 60)), color: black, size: 4)
        let c = canvas([b])
        c.mouseDown(with: try mouse(.leftMouseDown, c, CGPoint(x: 100, y: 130)))      // b に触れて押す（離す操作は、来ない）
        #expect(c.isInteracting)
        try drag(c, [CGPoint(x: 400, y: 300), CGPoint(x: 420, y: 300)])                // 何もない所で、別のドラッグ
        #expect(c.document.items.count == 1 && !c.isInteracting)
    }

    @Test("拡大縮小したままでも、ポインタの半径は、画面で同じ：縮小すると、キャンバスでは広く触れる")
    func radiusIsScreenSized() throws {
        let line = Item(content: .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100)), color: black, size: 2)
        let far = CGPoint(x: 200, y: 100 + 20)                                    // 線から 20 pt（キャンバス）
        let normal = canvas([line])
        try drag(normal, [far])
        #expect(normal.document.items.count == 1)                                // 等倍：半径 8 pt では、届かない
        let zoomedOut = canvas([line])
        zoomedOut.zoomViewport(by: 0.25, at: .zero)                              // 25%：画面の 8 pt ＝ キャンバスの 32 pt
        try drag(zoomedOut, [far])
        #expect(zoomedOut.document.items.isEmpty)
    }

    @Test("背景の画像は、消えない（文書から要素を消しても、背景は残る）")
    func backgroundStays() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = ImportedImage(cgImage: try #require(ctx.makeImage()), pointSize: CGSize(width: 480, height: 320))
        let doc = Document(background: image, backgroundRect: CGRect(x: 0, y: 0, width: 480, height: 320)).appending(pen([(10, 10), (20, 20)]))
        let removed = try #require(doc.removingItems(at: [0]))
        #expect(removed.items.isEmpty && removed.background != nil && removed.backgroundRect == CGRect(x: 0, y: 0, width: 480, height: 320))
        // 背景しかないキャンバスを、全面なぞっても、何も起きない（背景は、要素ではない）
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.tool = .eraser
        try drag(c, [CGPoint(x: 0, y: 0), CGPoint(x: 480, y: 320)])
        #expect(c.document.items.isEmpty)
    }
}
