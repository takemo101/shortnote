import AppKit
import Testing
@testable import ShortNoteKit

private func pixelImage() -> ImportedImage {
    let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return ImportedImage(cgImage: ctx.makeImage()!, pointSize: CGSize(width: 2, height: 2))
}

private let black = CGColor(gray: 0, alpha: 1)

private func imageItem(_ box: CGRect) -> Item { Item(content: .image(pixelImage(), box: box), color: black, size: 0) }
private func rectItem(_ r: CGRect, filled: Bool = false) -> Item { Item(content: .rect(r), color: black, size: 4, filled: filled) }
private func ellipseItem(_ r: CGRect) -> Item { Item(content: .ellipse(r), color: black, size: 4) }
private func lineItem(_ a: CGPoint, _ b: CGPoint) -> Item { Item(content: .line(from: a, to: b), color: black, size: 4) }

@Suite("画像・円・四角・直線の大きさの変更（SPEC §3.2.3、A28・A29）")
struct ItemResizeTests {
    // MARK: 枠の幾何

    private let original = CGRect(x: 100, y: 100, width: 200, height: 100)   // 縦横比 2:1

    @Test("縦横比を保つ：ポインタに合わせて、大きいほうの辺に揃う。反対側の角は動かない")
    func keepsAspect() {
        let toBigX = ItemResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 400, y: 150), keepAspect: true)
        #expect(toBigX == CGRect(x: 100, y: 100, width: 300, height: 150))
        let toBigY = ItemResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 150, y: 400), keepAspect: true)
        #expect(toBigY == CGRect(x: 100, y: 100, width: 600, height: 300))
    }

    @Test("どの角でも、反対側の角の位置は変わらない")
    func anchorStays() {
        for corner in ItemResize.Corner.allCases {
            let anchor = corner.opposite.point(in: original)
            let grabbed = corner.point(in: original)
            let pointer = CGPoint(x: grabbed.x + (grabbed.x > anchor.x ? 30 : -30), y: grabbed.y + (grabbed.y > anchor.y ? 20 : -20))
            for keep in [true, false] {
                let box = ItemResize.box(original: original, corner: corner, pointer: pointer, keepAspect: keep)
                #expect(corner.opposite.point(in: box) == anchor, "\(corner) keepAspect=\(keep)")
                #expect(box.width > original.width && box.height > original.height)
            }
        }
    }

    @Test("縦横比を保つとき、結果の縦横比は、元と同じ")
    func aspectIsExact() {
        for corner in ItemResize.Corner.allCases {
            let box = ItemResize.box(original: original, corner: corner, pointer: CGPoint(x: 37, y: 411), keepAspect: true)
            #expect(abs(box.width / box.height - 2) < 1e-9, "\(corner)")
        }
    }

    @Test("保たない：ポインタのとおりに、縦横を別々に変える")
    func freeResize() {
        let box = ItemResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 400, y: 130), keepAspect: false)
        #expect(box == CGRect(x: 100, y: 100, width: 300, height: 30))
    }

    @Test("短い辺は下限を下回らない（縦横比を保つときは、保ったまま大きくする）。下限は、画像 8 pt・円と四角 1 pt")
    func minimumSide() {
        let atAnchor = ItemResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 100, y: 100), keepAspect: true)
        #expect(atAnchor.height == ItemResize.imageMinSide && atAnchor.width == 2 * ItemResize.imageMinSide)
        let free = ItemResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 101, y: 300), keepAspect: false)
        #expect(free.width == ItemResize.imageMinSide && free.height == 200)
        let shape = ItemResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 100, y: 100), keepAspect: false, minSide: ItemResize.shapeMinSide)
        #expect(shape.size == CGSize(width: 1, height: 1))
    }

    @Test("反対側の角を越えると、枠は反対向きに伸びる（反転せず、枠だけ）")
    func crossingTheAnchor() {
        // 左上の取っ手を、右下の角（300, 200）より右下へ
        let box = ItemResize.box(original: original, corner: .topLeft, pointer: CGPoint(x: 400, y: 260), keepAspect: false)
        #expect(box == CGRect(x: 300, y: 200, width: 100, height: 60))
    }

    @Test("元の短い辺が下限未満の要素：掴んだ角のままなら、そのまま。触っただけで跳ねない")
    func tinyOriginalDoesNotJump() {
        let wide = CGRect(x: 10, y: 10, width: 336, height: 0.336)   // 1000:1
        for corner in ItemResize.Corner.allCases {
            #expect(ItemResize.box(original: wide, corner: corner, pointer: corner.point(in: wide), keepAspect: true) == wide)
        }
        let slightly = ItemResize.box(original: wide, corner: .bottomRight, pointer: CGPoint(x: wide.maxX + 10, y: wide.maxY), keepAspect: true)
        #expect(slightly.width < 400 && abs(slightly.width / slightly.height - 1000) < 1e-6)   // 幅が 8000 などへ跳ねない
        let small = CGRect(x: 0, y: 0, width: 2, height: 1)
        #expect(ItemResize.box(original: small, corner: .bottomRight, pointer: CGPoint(x: 2, y: 1), keepAspect: false) == small)
    }

    @Test("ポインタが掴んだ角のままなら、元の枠そのもの（誤差で、動いたことにならない）")
    func noMovementReturnsTheOriginal() {
        let odd = CGRect(x: 100.3, y: 100.3, width: 200.7, height: 100.1)
        for corner in ItemResize.Corner.allCases {
            for keep in [true, false] {
                #expect(ItemResize.box(original: odd, corner: corner, pointer: corner.point(in: odd), keepAspect: keep) == odd)
            }
        }
    }

    // MARK: 取っ手の掴める範囲

    @Test("枠の取っ手：角の近くだけ。中や辺の途中は掴めない。近い角を選ぶ")
    func cornerHitTest() {
        let shape = ItemResize.Shape.box(original)
        #expect(ItemResize.handle(at: CGPoint(x: 103, y: 96), in: shape) == .corner(.topLeft))
        #expect(ItemResize.handle(at: CGPoint(x: 297, y: 203), in: shape) == .corner(.bottomRight))
        #expect(ItemResize.handle(at: CGPoint(x: 200, y: 150), in: shape) == nil)
        #expect(ItemResize.handle(at: CGPoint(x: 200, y: 100), in: shape) == nil)
        let tiny = ItemResize.Shape.box(CGRect(x: 0, y: 0, width: 8, height: 8))   // 取っ手同士が重なる小ささ
        #expect(ItemResize.handle(at: CGPoint(x: 7, y: 7), in: tiny) == .corner(.bottomRight))
        #expect(ItemResize.handle(at: CGPoint(x: 1, y: 1), in: tiny) == .corner(.topLeft))
    }

    @Test("小さい枠：内側の取っ手の範囲は、辺の 1/4 まで。中央は掴んで動かせる")
    func smallBoxCenterIsNotAHandle() {
        let small = ItemResize.Shape.box(CGRect(x: 100, y: 100, width: 12, height: 12))
        #expect(ItemResize.handle(at: CGPoint(x: 106, y: 106), in: small) == nil)
        #expect(ItemResize.handle(at: CGPoint(x: 102, y: 102), in: small) == .corner(.topLeft))
        #expect(ItemResize.handle(at: CGPoint(x: 94, y: 94), in: small) == .corner(.topLeft))   // 外側は、これまでと同じ
    }

    @Test("直線の取っ手：両端の近くだけ。中は掴めない。短い直線では、内側へ狭める（中を掴んで動かせる）")
    func lineHitTest() {
        let long = ItemResize.Shape.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        #expect(ItemResize.handle(at: CGPoint(x: 103, y: 97), in: long) == .lineStart)
        #expect(ItemResize.handle(at: CGPoint(x: 297, y: 204), in: long) == .lineEnd)
        #expect(ItemResize.handle(at: CGPoint(x: 200, y: 150), in: long) == nil)
        let short = ItemResize.Shape.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 12, y: 0))   // 長さ 12：半径 3
        #expect(ItemResize.handle(at: CGPoint(x: 6, y: 0), in: short) == nil)
        #expect(ItemResize.handle(at: CGPoint(x: 2, y: 0), in: short) == .lineStart)
        #expect(ItemResize.handle(at: CGPoint(x: -5, y: 0), in: short) == .lineStart)   // 外側は、短くても 7 pt（見えている取っ手の上を、掴める）
        #expect(ItemResize.handle(at: CGPoint(x: -4, y: -4), in: short) == .lineStart)   // 見えている 9 pt の取っ手の角
        #expect(ItemResize.handle(at: CGPoint(x: -9, y: 0), in: short) == nil)
        #expect(ItemResize.handle(at: .zero, in: .line(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5))) == nil)   // 長さ 0
    }

    // MARK: 形の計算（枠と直線）

    @Test("直線：掴んだ端だけが動き、反対の端は動かない")
    func lineEndpoints() {
        let line = ItemResize.Shape.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        let start = ItemResize.resized(line, handle: .lineStart, pointer: CGPoint(x: 50, y: 20), keepAspect: false, minSide: 0)
        #expect(start == .line(from: CGPoint(x: 50, y: 20), to: CGPoint(x: 300, y: 200)))
        let end = ItemResize.resized(line, handle: .lineEnd, pointer: CGPoint(x: 400, y: 10), keepAspect: true, minSide: 0)   // keepAspect は効かない
        #expect(end == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 10)))
    }

    @Test("直線：長さが 1 pt 未満になる位置では nil（直前の形のまま）。掴んだ位置のままなら、元のまま")
    func lineMinimumLength() {
        let line = ItemResize.Shape.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        #expect(ItemResize.resized(line, handle: .lineEnd, pointer: CGPoint(x: 100.5, y: 100), keepAspect: false, minSide: 0) == nil)
        #expect(ItemResize.resized(line, handle: .lineEnd, pointer: CGPoint(x: 101, y: 100), keepAspect: false, minSide: 0) != nil)
        #expect(ItemResize.resized(line, handle: .lineEnd, pointer: CGPoint(x: 300, y: 200), keepAspect: false, minSide: 0) == line)
    }

    @Test("取っ手の種類が形に合わないとき（枠に直線の端など）は nil")
    func mismatchedHandle() {
        #expect(ItemResize.resized(.box(original), handle: .lineEnd, pointer: .zero, keepAspect: false, minSide: 1) == nil)
        #expect(ItemResize.resized(.line(from: .zero, to: CGPoint(x: 10, y: 10)), handle: .corner(.topLeft), pointer: .zero, keepAspect: false, minSide: 1) == nil)
    }

    // MARK: 文書

    @Test("大きさを変えられるのは、画像・円・四角・直線。ペン・文字・範囲外は nil。規則は種類で決まる")
    func documentTargets() {
        let pen = Item(content: .pen(points: [StrokePoint(point: CGPoint(x: 1, y: 1), pressure: 1)]), color: black, size: 4)
        let text = Item(content: .text("a", box: CGRect(x: 0, y: 0, width: 10, height: 10)), color: black, size: 18)
        let doc = Document().appending(contentsOf: [pen, text, imageItem(original), rectItem(original), ellipseItem(original), lineItem(.zero, CGPoint(x: 5, y: 5))])
        #expect(doc.resizeTarget(at: 0) == nil && doc.resizeTarget(at: 1) == nil && doc.resizeTarget(at: 6) == nil && doc.resizeTarget(at: -1) == nil)
        #expect(doc.resizeTarget(at: 2)?.keepsAspect == true && doc.resizeTarget(at: 2)?.minSide == ItemResize.imageMinSide)
        #expect(doc.resizeTarget(at: 3)?.keepsAspect == false && doc.resizeTarget(at: 3)?.minSide == ItemResize.shapeMinSide)
        #expect(doc.resizeTarget(at: 4)?.shape == .box(original))
        #expect(doc.resizeTarget(at: 5)?.shape == .line(from: .zero, to: CGPoint(x: 5, y: 5)))
    }

    @Test("形を変えても、色・太さ・塗りつぶしは、そのまま。種類と形が合わないときは nil。元の文書は変わらない")
    func documentApplying() {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        var filled = rectItem(original, filled: true)
        filled.color = red
        let doc = Document().appending(contentsOf: [filled, lineItem(.zero, CGPoint(x: 5, y: 5))])
        let bigger = CGRect(x: 0, y: 0, width: 50, height: 50)
        let resized = doc.applying(.box(bigger), toItemAt: 0)
        #expect(resized?.resizeTarget(at: 0)?.shape == .box(bigger))
        #expect(resized?.items[0].filled == true && resized?.items[0].size == 4 && resized?.items[0].color == red)
        #expect(doc.applying(.line(from: .zero, to: CGPoint(x: 1, y: 1)), toItemAt: 0) == nil)
        #expect(doc.applying(.box(bigger), toItemAt: 1) == nil)
        #expect(doc.applying(.box(bigger), toItemAt: 9) == nil)
        #expect(doc.resizeTarget(at: 0)?.shape == .box(original))
    }

    // MARK: キャンバス

    private func canvas(_ items: [Item]) -> CanvasView {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.appendFromAgent(items)
        canvas.tool = .move
        return canvas
    }

    private func canvasWithImage() -> CanvasView { canvas([imageItem(CGRect(x: 100, y: 100, width: 200, height: 100))]) }

    private func event(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint, shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: canvas.convert(p, to: nil), modifierFlags: shift ? [.shift] : [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func down(_ c: CanvasView, _ p: CGPoint) throws { c.mouseDown(with: try event(.leftMouseDown, c, p)) }
    private func drag(_ c: CanvasView, _ p: CGPoint, shift: Bool = false) throws { c.mouseDragged(with: try event(.leftMouseDragged, c, p, shift: shift)) }
    private func up(_ c: CanvasView, _ p: CGPoint) throws { c.mouseUp(with: try event(.leftMouseUp, c, p)) }
    private func click(_ c: CanvasView, _ p: CGPoint) throws { try down(c, p); try up(c, p) }

    private func shape(_ c: CanvasView, _ index: Int = 0) -> ItemResize.Shape? { c.document.resizeTarget(at: index)?.shape }
    private func box(_ c: CanvasView, _ index: Int = 0) -> CGRect? {
        if case .box(let b)? = shape(c, index) { return b }
        return nil
    }

    @Test("移動ツールで画像・円・四角・直線をクリックすると選ばれる。ペン・文字・何もない所・ツールの切り替えで外れる")
    func selection() throws {
        let pen = Item(content: .pen(points: [StrokePoint(point: CGPoint(x: 400, y: 20), pressure: 1), StrokePoint(point: CGPoint(x: 440, y: 60), pressure: 1)]), color: black, size: 4)
        let c = canvas([imageItem(CGRect(x: 20, y: 20, width: 80, height: 60)), rectItem(CGRect(x: 120, y: 20, width: 80, height: 60)),
                        ellipseItem(CGRect(x: 220, y: 20, width: 80, height: 60)), lineItem(CGPoint(x: 20, y: 200), CGPoint(x: 300, y: 260)), pen])
        try click(c, CGPoint(x: 60, y: 50)); #expect(c.selectedItem == 0)
        try click(c, CGPoint(x: 160, y: 50)); #expect(c.selectedItem == 1)
        try click(c, CGPoint(x: 260, y: 50)); #expect(c.selectedItem == 2)
        try click(c, CGPoint(x: 160, y: 230)); #expect(c.selectedItem == 3)
        try click(c, CGPoint(x: 420, y: 40)); #expect(c.selectedItem == nil)   // ペンの線は、選ばれない
        try click(c, CGPoint(x: 160, y: 50)); try click(c, CGPoint(x: 20, y: 300)); #expect(c.selectedItem == nil)
        try click(c, CGPoint(x: 160, y: 50)); c.tool = .pen; #expect(c.selectedItem == nil)
    }

    @Test("画像の角の取っ手：縦横比を保って拡大する。掴んだ位置から飛ばない。1 回が取り消し 1 段で、やり直せる")
    func imageResizeDragIsOneUndoStep() throws {
        let c = canvasWithImage()
        let original = try #require(box(c))
        try click(c, CGPoint(x: 200, y: 150))                                    // 選ぶ
        try down(c, CGPoint(x: 297, y: 203))                                     // 右下の角から、内側へ (-3, +3) ずれた位置
        try drag(c, CGPoint(x: 347, y: 203))                                     // 右へ 50
        #expect(box(c)?.size == CGSize(width: 250, height: 125))                 // 角の位置（300, 200）+ 50 → 幅 250、縦横比 2:1
        try drag(c, CGPoint(x: 397, y: 203))
        try up(c, CGPoint(x: 397, y: 203))
        let resized = try #require(box(c))
        #expect(resized.origin == original.origin && resized.size == CGSize(width: 300, height: 150))
        #expect(c.document.items.count == 1)
        #expect(c.selectedItem == 0)                                             // 拡大のあとも、選ばれたまま
        c.undo()
        #expect(box(c) == original)                                              // 2 回のドラッグの更新が、1 段
        c.undo()
        #expect(c.document.items.isEmpty)                                        // 次の段は、画像を足したこと
        c.redo(); c.redo()
        #expect(box(c) == resized)
    }

    @Test("画像：Shift を押している間は、縦横比を保たない")
    func shiftFreesAnImage() throws {
        let c = canvasWithImage()
        try click(c, CGPoint(x: 200, y: 150))
        try down(c, CGPoint(x: 300, y: 200))
        try drag(c, CGPoint(x: 400, y: 220), shift: true)
        try up(c, CGPoint(x: 400, y: 220))
        #expect(box(c) == CGRect(x: 100, y: 100, width: 300, height: 120))
    }

    @Test("四角：既定では縦横比を保たない（描くときと同じ）。Shift を押している間は、元の縦横比を保つ。色・太さ・塗りつぶしは、そのまま")
    func rectResize() throws {
        let c = canvas([rectItem(CGRect(x: 100, y: 100, width: 200, height: 100), filled: true)])
        let before = c.document.items[0]
        try click(c, CGPoint(x: 200, y: 150))
        #expect(c.selectedItem == 0)
        try down(c, CGPoint(x: 300, y: 200)); try drag(c, CGPoint(x: 400, y: 220)); try up(c, CGPoint(x: 400, y: 220))
        #expect(box(c) == CGRect(x: 100, y: 100, width: 300, height: 120))
        let after = c.document.items[0]
        #expect(after.filled && after.size == before.size && after.color == before.color)
        try down(c, CGPoint(x: 400, y: 220)); try drag(c, CGPoint(x: 400, y: 320), shift: true); try up(c, CGPoint(x: 400, y: 320))
        let kept = try #require(box(c))
        #expect(abs(kept.width / kept.height - 300.0 / 120.0) < 1e-9)           // Shift：直前の縦横比（300:120）を保つ
        c.undo(); #expect(box(c) == CGRect(x: 100, y: 100, width: 300, height: 120))
        c.undo(); #expect(box(c) == CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    @Test("円：角の取っ手で、枠が変わる。反対側の角を越えると、反対向きに伸びる")
    func ellipseResize() throws {
        let c = canvas([ellipseItem(CGRect(x: 100, y: 100, width: 200, height: 100))])
        try click(c, CGPoint(x: 200, y: 150))
        try down(c, CGPoint(x: 100, y: 100)); try drag(c, CGPoint(x: 340, y: 240)); try up(c, CGPoint(x: 340, y: 240))   // 左上の取っ手を、右下の角（300, 200）より先へ
        #expect(box(c) == CGRect(x: 300, y: 200, width: 40, height: 40))
    }

    @Test("直線：端の取っ手のドラッグで、掴んだ端だけが動く。取り消しで戻る。長さが 1 pt 未満になる位置では、直前の位置のまま")
    func lineResize() throws {
        let c = canvas([lineItem(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))])
        try click(c, CGPoint(x: 200, y: 150))
        #expect(c.selectedItem == 0)
        try down(c, CGPoint(x: 300, y: 200))
        try drag(c, CGPoint(x: 380, y: 120))
        try up(c, CGPoint(x: 380, y: 120))
        #expect(shape(c) == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 380, y: 120)))
        try down(c, CGPoint(x: 100, y: 100))
        try drag(c, CGPoint(x: 380.4, y: 120))                                  // 反対の端から 0.4 pt：下限未満
        try up(c, CGPoint(x: 380.4, y: 120))
        #expect(shape(c) == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 380, y: 120)))   // 動かず、段も積まない
        c.undo()
        #expect(shape(c) == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200)))
        c.redo()
        #expect(shape(c) == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 380, y: 120)))
    }

    @Test("取っ手を押しただけ（動かさない）では、取り消しの段を作らず、形も変わらない（図形・直線・画像）")
    func clickingAHandleDoesNothing() throws {
        let c = canvas([rectItem(CGRect(x: 100.3, y: 100.3, width: 200.7, height: 100.1)), lineItem(CGPoint(x: 10.3, y: 200.7), CGPoint(x: 90.1, y: 250.2))])
        let before = (shape(c, 0), shape(c, 1))
        try click(c, CGPoint(x: 200, y: 150))
        try click(c, CGPoint(x: 301, y: 200)); try click(c, CGPoint(x: 100, y: 100))
        try click(c, CGPoint(x: 50, y: 225)); try click(c, CGPoint(x: 90, y: 250)); try click(c, CGPoint(x: 10, y: 201))
        #expect(shape(c, 0) == before.0 && shape(c, 1) == before.1)
        c.undo()
        #expect(c.document.items.isEmpty)          // 最初の取り消しが、要素を足した段（拡大の段は、無い）
    }

    @Test("縁の外にある取っ手は、触っただけでは、縁へ跳ねず、取り消しの段も作らない。動かしたあとは、さらに外へは出ない")
    func handleOutsideTheCanvasDoesNotJump() throws {
        let c = canvas([lineItem(CGPoint(x: 300, y: 100), CGPoint(x: 485, y: 100))])    // 終点が、キャンバス（幅 480）の外にある
        try click(c, CGPoint(x: 400, y: 100))
        try down(c, CGPoint(x: 480, y: 100)); try drag(c, CGPoint(x: 480, y: 100)); try up(c, CGPoint(x: 480, y: 100))
        #expect(shape(c) == .line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 485, y: 100)))
        c.undo()
        #expect(c.document.items.isEmpty)                                        // 拡大の段は、無い（最初の取り消しが、足した段）
        c.redo()
        try click(c, CGPoint(x: 400, y: 100))
        try down(c, CGPoint(x: 480, y: 100)); try drag(c, CGPoint(x: 600, y: 100)); try up(c, CGPoint(x: 600, y: 100))
        #expect(shape(c) == .line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 485, y: 100)))   // 485 より外へは、出ない
    }

    @Test("ごく小さい枠（短い辺が 4 pt 未満）には、取っ手を出さない。選ばれていても、ドラッグは、動かす")
    func tinyBoxesAreMovable() throws {
        let c = canvas([rectItem(CGRect(x: 100, y: 100, width: 2, height: 2))])
        try click(c, CGPoint(x: 101, y: 101))
        #expect(c.selectedItem == 0)
        try down(c, CGPoint(x: 101, y: 101)); try drag(c, CGPoint(x: 151, y: 131)); try up(c, CGPoint(x: 151, y: 131))
        #expect(box(c) == CGRect(x: 150, y: 130, width: 2, height: 2))            // 大きさは変わらず、動いた
        #expect(ItemResize.handles(of: .box(CGRect(x: 0, y: 0, width: 3.9, height: 50))).isEmpty)
        #expect(ItemResize.handles(of: .box(CGRect(x: 0, y: 0, width: 4, height: 4))).count == 4)
    }

    @Test("選ばれていない要素の角は、取っ手ではない（掴んで、動かす）。選ばれた要素の取っ手は、上に重なる別の要素より先に掴める")
    func handlesComeFirst() throws {
        let c = canvasWithImage()
        // 選ばれていないときは、角を掴むと、画像を動かす
        try down(c, CGPoint(x: 300, y: 200)); try drag(c, CGPoint(x: 320, y: 200)); try up(c, CGPoint(x: 320, y: 200))
        #expect(box(c)?.origin == CGPoint(x: 120, y: 100) && box(c)?.size == CGSize(width: 200, height: 100))
        // 右下（320, 200）に、前面の四角を重ねる。選ばれた画像の取っ手が先
        c.appendFromAgent([rectItem(CGRect(x: 300, y: 180, width: 40, height: 40))])
        #expect(c.selectedItem == 0)
        try down(c, CGPoint(x: 320, y: 200)); try drag(c, CGPoint(x: 420, y: 200)); try up(c, CGPoint(x: 420, y: 200))
        #expect(box(c)?.size == CGSize(width: 300, height: 150))
        #expect(c.document.items[1].bounds == CGRect(x: 300, y: 180, width: 40, height: 40).insetBy(dx: -2, dy: -2))
    }

    @Test("掴んだ差を足したあとも、ポインタは縁に丸める：枠がキャンバスの外へ出てしまわない")
    func resizeCannotLeaveTheCanvas() throws {
        let c = canvasWithImage()
        try down(c, CGPoint(x: 200, y: 150)); try drag(c, CGPoint(x: 10, y: 150)); try up(c, CGPoint(x: 10, y: 150))   // 左へ寄せる
        let moved = try #require(box(c))
        try down(c, CGPoint(x: moved.maxX + 6, y: moved.maxY))       // 右下の取っ手を、角の 6 pt 外から掴む
        try drag(c, CGPoint(x: 0, y: moved.minY + 10))               // 縦は近く、横に長く伸ばす（縦横比を保つ計算が、横で決まる）
        try up(c, CGPoint(x: 0, y: moved.minY + 10))
        let resized = try #require(box(c))
        #expect(resized.maxX >= 0 && resized.maxY >= 0 && resized.maxX <= 480)
    }

    @Test("ドラッグの途中で、エージェントが足した要素は、残る。取り消しで、拡大の前（足す前）に戻る")
    func agentAppendDuringResize() throws {
        let c = canvasWithImage()
        let original = try #require(box(c))
        try click(c, CGPoint(x: 200, y: 150))
        try down(c, CGPoint(x: 300, y: 200))
        try drag(c, CGPoint(x: 400, y: 200))
        c.appendFromAgent([rectItem(CGRect(x: 10, y: 10, width: 20, height: 20))])
        try drag(c, CGPoint(x: 450, y: 200))
        try up(c, CGPoint(x: 450, y: 200))
        #expect(c.document.items.count == 2)
        #expect(box(c)?.size == CGSize(width: 350, height: 175))
        c.undo()   // 拡大
        #expect(c.document.items.count == 2 && box(c) == original)
    }

    @Test("取り消し・やり直し・クリアで、選びが外れる。外れたあと、別の要素の同じ番号を、誤って選ばない")
    func selectionClears() throws {
        let c = canvasWithImage()
        try click(c, CGPoint(x: 200, y: 150))
        c.undo()
        #expect(c.selectedItem == nil)
        c.redo()
        try click(c, CGPoint(x: 200, y: 150))
        c.clearCanvas()
        #expect(c.selectedItem == nil)
        c.undo()
        try click(c, CGPoint(x: 200, y: 150))
        #expect(c.clearFromAgent())
        #expect(c.selectedItem == nil)
    }

    @Test("取っ手と枠は、書き出し PNG に入らない（選ばれていても、書き出しは同じ）。円・四角・直線でも")
    func handlesAreNotExported() throws {
        for item in [imageItem(CGRect(x: 100, y: 100, width: 200, height: 100)), rectItem(CGRect(x: 100, y: 100, width: 200, height: 100)),
                     lineItem(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))] {
            let c = canvas([item])
            let before = try #require(c.renderPNG())
            try click(c, CGPoint(x: 200, y: 150))
            #expect(c.selectedItem == 0)
            #expect(try #require(c.renderPNG()) == before)
        }
    }
}
