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

private func imageItem(_ box: CGRect) -> Item {
    Item(content: .image(pixelImage(), box: box), color: CGColor(gray: 0, alpha: 1), size: 0)
}

private func rectItem(_ r: CGRect) -> Item {
    Item(content: .rect(r), color: CGColor(gray: 0, alpha: 1), size: 4)
}

@Suite("画像の拡大縮小（SPEC §3.2.3、A28）")
struct ImageResizeTests {
    // MARK: 幾何

    private let original = CGRect(x: 100, y: 100, width: 200, height: 100)   // 縦横比 2:1

    @Test("縦横比を保つ：ポインタに合わせて、大きいほうの辺に揃う。反対側の角は動かない")
    func keepsAspect() {
        let toBigX = ImageResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 400, y: 150), keepAspect: true)
        #expect(toBigX == CGRect(x: 100, y: 100, width: 300, height: 150))
        let toBigY = ImageResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 150, y: 400), keepAspect: true)
        #expect(toBigY == CGRect(x: 100, y: 100, width: 600, height: 300))
    }

    @Test("どの角でも、反対側の角の位置は変わらない")
    func anchorStays() {
        for corner in ImageResize.Corner.allCases {
            let anchor = corner.opposite.point(in: original)
            let grabbed = corner.point(in: original)
            let pointer = CGPoint(x: grabbed.x + (grabbed.x > anchor.x ? 30 : -30), y: grabbed.y + (grabbed.y > anchor.y ? 20 : -20))
            for keep in [true, false] {
                let box = ImageResize.box(original: original, corner: corner, pointer: pointer, keepAspect: keep)
                #expect(corner.opposite.point(in: box) == anchor, "\(corner) keepAspect=\(keep)")
                #expect(box.width > original.width && box.height > original.height)
            }
        }
    }

    @Test("縦横比を保つとき、結果の縦横比は、元と同じ")
    func aspectIsExact() {
        for corner in ImageResize.Corner.allCases {
            let box = ImageResize.box(original: original, corner: corner, pointer: CGPoint(x: 37, y: 411), keepAspect: true)
            #expect(abs(box.width / box.height - 2) < 1e-9, "\(corner)")
        }
    }

    @Test("Shift（保たない）：ポインタのとおりに、縦横を別々に変える")
    func freeResize() {
        let box = ImageResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 400, y: 130), keepAspect: false)
        #expect(box == CGRect(x: 100, y: 100, width: 300, height: 30))
    }

    @Test("短い辺は 8 pt を下回らない（縦横比を保つときは、保ったまま大きくする）")
    func minimumSide() {
        let atAnchor = ImageResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 100, y: 100), keepAspect: true)
        #expect(atAnchor.height == ImageResize.minSide && atAnchor.width == 2 * ImageResize.minSide)
        let free = ImageResize.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 101, y: 300), keepAspect: false)
        #expect(free.width == ImageResize.minSide && free.height == 200)
    }

    @Test("反対側の角を越えると、枠は反対向きに伸びる（反転せず、枠だけ）")
    func crossingTheAnchor() {
        // 左上の取っ手を、右下の角（300, 200）より右下へ
        let box = ImageResize.box(original: original, corner: .topLeft, pointer: CGPoint(x: 400, y: 260), keepAspect: false)
        #expect(box == CGRect(x: 300, y: 200, width: 100, height: 60))
    }

    @Test("取っ手の掴める範囲：角の近くだけ。中や辺の途中は掴めない。近い角を選ぶ")
    func cornerHitTest() {
        #expect(ImageResize.corner(at: CGPoint(x: 103, y: 96), in: original) == .topLeft)
        #expect(ImageResize.corner(at: CGPoint(x: 297, y: 203), in: original) == .bottomRight)
        #expect(ImageResize.corner(at: CGPoint(x: 200, y: 150), in: original) == nil)
        #expect(ImageResize.corner(at: CGPoint(x: 200, y: 100), in: original) == nil)
        let tiny = CGRect(x: 0, y: 0, width: 8, height: 8)   // 取っ手同士が重なる小ささ
        #expect(ImageResize.corner(at: CGPoint(x: 7, y: 7), in: tiny) == .bottomRight)
        #expect(ImageResize.corner(at: CGPoint(x: 1, y: 1), in: tiny) == .topLeft)
    }

    @Test("元の短い辺が 8 pt 未満の画像：掴んだ角のままなら、そのまま。触っただけで 8 pt へ跳ねない")
    func tinyOriginalDoesNotJump() {
        let wide = CGRect(x: 10, y: 10, width: 336, height: 0.336)   // 1000:1
        for corner in ImageResize.Corner.allCases {
            #expect(ImageResize.box(original: wide, corner: corner, pointer: corner.point(in: wide), keepAspect: true) == wide)
        }
        let slightly = ImageResize.box(original: wide, corner: .bottomRight, pointer: CGPoint(x: wide.maxX + 10, y: wide.maxY), keepAspect: true)
        #expect(slightly.width < 400 && abs(slightly.width / slightly.height - 1000) < 1e-6)   // 幅が 8000 などへ跳ねない
        let small = CGRect(x: 0, y: 0, width: 2, height: 1)
        #expect(ImageResize.box(original: small, corner: .bottomRight, pointer: CGPoint(x: 2, y: 1), keepAspect: false) == small)
    }

    @Test("ポインタが掴んだ角のままなら、元の枠そのもの（誤差で、動いたことにならない）")
    func noMovementReturnsTheOriginal() {
        let odd = CGRect(x: 100.3, y: 100.3, width: 200.7, height: 100.1)
        for corner in ImageResize.Corner.allCases {
            for keep in [true, false] {
                #expect(ImageResize.box(original: odd, corner: corner, pointer: corner.point(in: odd), keepAspect: keep) == odd)
            }
        }
    }

    @Test("小さい画像：内側の取っ手の範囲は、辺の 1/4 まで。中央は掴んで動かせる")
    func smallImageCenterIsNotAHandle() {
        let small = CGRect(x: 100, y: 100, width: 12, height: 12)
        #expect(ImageResize.corner(at: CGPoint(x: 106, y: 106), in: small) == nil)
        #expect(ImageResize.corner(at: CGPoint(x: 102, y: 102), in: small) == .topLeft)
        #expect(ImageResize.corner(at: CGPoint(x: 94, y: 94), in: small) == .topLeft)   // 外側は、これまでと同じ
    }

    // MARK: 文書

    @Test("画像だけが、大きさを変えられる。図形・範囲外・背景は変えない")
    func documentOnlyResizesImages() {
        let doc = Document().appending(contentsOf: [rectItem(CGRect(x: 0, y: 0, width: 10, height: 10)), imageItem(original)])
        #expect(doc.imageBox(at: 0) == nil && doc.imageBox(at: 1) == original && doc.imageBox(at: 2) == nil)
        #expect(doc.resizingImage(at: 0, to: .zero) == nil)
        #expect(doc.resizingImage(at: 5, to: .zero) == nil)
        let bigger = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(doc.resizingImage(at: 1, to: bigger)?.imageBox(at: 1) == bigger)
        #expect(doc.imageBox(at: 1) == original)   // 元の文書は変わらない
    }

    // MARK: キャンバス

    private func canvasWithImage(shift: Bool = false) -> CanvasView {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.appendFromAgent([imageItem(CGRect(x: 100, y: 100, width: 200, height: 100))])
        canvas.tool = .move
        return canvas
    }

    private func event(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint, shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: canvas.convert(p, to: nil), modifierFlags: shift ? [.shift] : [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func down(_ c: CanvasView, _ p: CGPoint) throws { c.mouseDown(with: try event(.leftMouseDown, c, p)) }
    private func drag(_ c: CanvasView, _ p: CGPoint, shift: Bool = false) throws { c.mouseDragged(with: try event(.leftMouseDragged, c, p, shift: shift)) }
    private func up(_ c: CanvasView, _ p: CGPoint) throws { c.mouseUp(with: try event(.leftMouseUp, c, p)) }

    private func box(_ c: CanvasView) -> CGRect? { c.document.imageBox(at: 0) }

    @Test("移動ツールで画像をクリックすると選ばれる。図形・何もない所・ツールの切り替えで外れる")
    func selection() throws {
        let canvas = canvasWithImage()
        canvas.appendFromAgent([rectItem(CGRect(x: 350, y: 10, width: 50, height: 50))])
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        #expect(canvas.selectedImage == 0)
        try down(canvas, CGPoint(x: 370, y: 30)); try up(canvas, CGPoint(x: 370, y: 30))
        #expect(canvas.selectedImage == nil)
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        try down(canvas, CGPoint(x: 20, y: 300)); try up(canvas, CGPoint(x: 20, y: 300))
        #expect(canvas.selectedImage == nil)
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        canvas.tool = .pen
        #expect(canvas.selectedImage == nil)
    }

    @Test("角の取っ手のドラッグで、縦横比を保って拡大する。掴んだ位置から飛ばない。1 回が取り消し 1 段で、やり直せる")
    func resizeDragIsOneUndoStep() throws {
        let canvas = canvasWithImage()
        let original = try #require(box(canvas))
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))   // 選ぶ
        try down(canvas, CGPoint(x: 297, y: 203))                 // 右下の角から、内側へ (-3, +3) ずれた位置
        try drag(canvas, CGPoint(x: 347, y: 203))                  // 右へ 50
        #expect(box(canvas)?.size == CGSize(width: 250, height: 125))   // 角の位置（300,200）+ 50 → 幅 250、縦横比 2:1
        try drag(canvas, CGPoint(x: 397, y: 203))
        try up(canvas, CGPoint(x: 397, y: 203))
        let resized = try #require(box(canvas))
        #expect(resized.origin == original.origin && resized.size == CGSize(width: 300, height: 150))
        #expect(canvas.document.items.count == 1)
        #expect(canvas.selectedImage == 0)        // 拡大のあとも、選ばれたまま

        canvas.undo()
        #expect(box(canvas) == original)           // 2 回のドラッグの更新が、1 段
        canvas.undo()
        #expect(canvas.document.items.isEmpty)     // 次の段は、画像を足したこと
        canvas.redo(); canvas.redo()
        #expect(box(canvas) == resized)
    }

    @Test("Shift を押している間は、縦横比を保たない")
    func shiftResizesFreely() throws {
        let canvas = canvasWithImage()
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        try down(canvas, CGPoint(x: 300, y: 200))
        try drag(canvas, CGPoint(x: 400, y: 220), shift: true)
        try up(canvas, CGPoint(x: 400, y: 220))
        #expect(box(canvas) == CGRect(x: 100, y: 100, width: 300, height: 120))
    }

    @Test("取っ手を押しただけ（動かさない）では、取り消しの段を作らず、大きさも変わらない")
    func clickingAHandleDoesNothing() throws {
        let canvas = canvasWithImage()
        let original = try #require(box(canvas))
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        try down(canvas, CGPoint(x: 300, y: 200)); try up(canvas, CGPoint(x: 300, y: 200))
        #expect(box(canvas) == original)
        canvas.undo()
        #expect(canvas.document.items.isEmpty)   // 最初の取り消しが、画像を足したこと（拡大の段は無い）
    }

    @Test("選ばれていない画像の角は、取っ手ではない（掴んで、動かす）。選ばれた画像の取っ手は、上に重なる別の要素より先に掴める")
    func handlesComeFirst() throws {
        let canvas = canvasWithImage()
        // 選ばれていないときは、角を掴むと、画像を動かす
        try down(canvas, CGPoint(x: 300, y: 200)); try drag(canvas, CGPoint(x: 320, y: 200)); try up(canvas, CGPoint(x: 320, y: 200))
        #expect(box(canvas)?.origin == CGPoint(x: 120, y: 100) && box(canvas)?.size == CGSize(width: 200, height: 100))
        // 右下（320,200）に、前面の四角を重ねる。選ばれた画像の取っ手が先
        canvas.appendFromAgent([rectItem(CGRect(x: 300, y: 180, width: 40, height: 40))])
        #expect(canvas.selectedImage == 0)
        try down(canvas, CGPoint(x: 320, y: 200)); try drag(canvas, CGPoint(x: 420, y: 200)); try up(canvas, CGPoint(x: 420, y: 200))
        #expect(box(canvas)?.size == CGSize(width: 300, height: 150))
        #expect(canvas.document.items[1].bounds == CGRect(x: 300, y: 180, width: 40, height: 40).insetBy(dx: -2, dy: -2))
    }

    @Test("掴んだ差を足したあとも、ポインタは縁に丸める：枠がキャンバスの外へ出てしまわない")
    func resizeCannotLeaveTheCanvas() throws {
        let canvas = canvasWithImage()
        try down(canvas, CGPoint(x: 200, y: 150)); try drag(canvas, CGPoint(x: 10, y: 150)); try up(canvas, CGPoint(x: 10, y: 150))   // 左へ寄せる
        let moved = try #require(box(canvas))
        try down(canvas, CGPoint(x: moved.maxX + 6, y: moved.maxY))       // 右下の取っ手を、角の 6 pt 外から掴む
        try drag(canvas, CGPoint(x: 0, y: moved.minY + 10))       // 縦は近く、横に長く伸ばす（縦横比を保つ計算が、横で決まる）
        try up(canvas, CGPoint(x: 0, y: moved.minY + 10))
        let resized = try #require(box(canvas))
        #expect(resized.maxX >= 0 && resized.maxY >= 0 && resized.maxX <= 480)
    }

    @Test("ドラッグの途中で、エージェントが足した要素は、残る。取り消しで、拡大の前（足す前）に戻る")
    func agentAppendDuringResize() throws {
        let canvas = canvasWithImage()
        let original = try #require(box(canvas))
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        try down(canvas, CGPoint(x: 300, y: 200))
        try drag(canvas, CGPoint(x: 400, y: 200))
        canvas.appendFromAgent([rectItem(CGRect(x: 10, y: 10, width: 20, height: 20))])
        try drag(canvas, CGPoint(x: 450, y: 200))
        try up(canvas, CGPoint(x: 450, y: 200))
        #expect(canvas.document.items.count == 2)
        #expect(box(canvas)?.size == CGSize(width: 350, height: 175))
        canvas.undo()   // 拡大
        #expect(canvas.document.items.count == 2 && box(canvas) == original)
    }

    @Test("取り消し・やり直し・クリアで、選びが外れる。外れたあと、別の画像の同じ番号を、誤って選ばない")
    func selectionClears() throws {
        let canvas = canvasWithImage()
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        canvas.undo()
        #expect(canvas.selectedImage == nil)
        canvas.redo()
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        canvas.clearCanvas()
        #expect(canvas.selectedImage == nil)
        canvas.undo()
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        #expect(canvas.clearFromAgent())
        #expect(canvas.selectedImage == nil)
    }

    @Test("取っ手と枠は、書き出し PNG に入らない（選ばれていても、書き出しは同じ）")
    func handlesAreNotExported() throws {
        let canvas = canvasWithImage()
        let before = try #require(canvas.renderPNG())
        try down(canvas, CGPoint(x: 200, y: 150)); try up(canvas, CGPoint(x: 200, y: 150))
        #expect(canvas.selectedImage == 0)
        #expect(try #require(canvas.renderPNG()) == before)
    }
}
