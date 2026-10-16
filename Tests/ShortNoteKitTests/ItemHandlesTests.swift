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
private let canvasRect = CGRect(x: 0, y: 0, width: 480, height: 320)

private func imageItem(_ box: CGRect) -> Item { Item(content: .image(pixelImage(), box: box), color: black, size: 0) }
private func rectItem(_ r: CGRect, filled: Bool = false, rotation: CGFloat = 0) -> Item {
    Item(content: .rect(r), color: black, size: 4, filled: filled, rotation: rotation)
}
private func ellipseItem(_ r: CGRect) -> Item { Item(content: .ellipse(r), color: black, size: 4) }
private func lineItem(_ a: CGPoint, _ b: CGPoint) -> Item { Item(content: .line(from: a, to: b), color: black, size: 4) }
private func penItem(_ points: [CGPoint]) -> Item {
    Item(content: .pen(points: points.map { StrokePoint(point: $0, pressure: 1) }), color: black, size: 4)
}
private func textItem(_ text: String = "Hello", at origin: CGPoint, fontSize: CGFloat = 18, rotation: CGFloat = 0) -> Item {
    let size = CanvasRenderer.textSize(text, size: fontSize, color: black)
    return Item(content: .text(text, box: CGRect(origin: origin, size: size)), color: black, size: fontSize, rotation: rotation)
}

private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tolerance }

@Suite("取っ手：大きさ・回転の幾何（SPEC §3.2.3、A28〜A31）")
struct ItemHandlesGeometryTests {
    private let original = CGRect(x: 100, y: 100, width: 200, height: 100)   // 縦横比 2:1

    // MARK: 角度

    @Test("回転は時計回りが正（y が下向き）。右の点は、90° で下へ来る")
    func rotationIsClockwise() {
        let p = ItemHandles.rotate(CGPoint(x: 1, y: 0), about: .zero, by: .pi / 2)
        #expect(near(p, CGPoint(x: 0, y: 1)))
        #expect(near(ItemHandles.rotate(CGPoint(x: 5, y: 3), about: CGPoint(x: 5, y: 3), by: 1), CGPoint(x: 5, y: 3)))
    }

    @Test("角度は (-π, π] に収める。15° きざみに丸める")
    func normalizedAndSnapped() {
        #expect(abs(ItemHandles.normalized(3 * .pi) - .pi) < 1e-9)
        #expect(abs(ItemHandles.normalized(-.pi)  - .pi) < 1e-9)
        #expect(abs(ItemHandles.normalized(.pi * 2.5) - .pi / 2) < 1e-9)
        #expect(abs(ItemHandles.snapped(20 * .pi / 180) - 15 * .pi / 180) < 1e-9)
        #expect(abs(ItemHandles.snapped(23 * .pi / 180) - 30 * .pi / 180) < 1e-9)
        #expect(abs(ItemHandles.snapped(-8 * .pi / 180)) < 1e-9 || abs(ItemHandles.snapped(-8 * .pi / 180) + 15 * .pi / 180) < 1e-9)
    }

    // MARK: 回っていない枠

    @Test("縦横比を保つ：ポインタに合わせて、大きいほうの辺に揃う。反対側の角は動かない")
    func keepsAspect() {
        let toBigX = ItemHandles.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 400, y: 150), keepAspect: true)
        #expect(toBigX == CGRect(x: 100, y: 100, width: 300, height: 150))
        let toBigY = ItemHandles.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 150, y: 400), keepAspect: true)
        #expect(toBigY == CGRect(x: 100, y: 100, width: 600, height: 300))
    }

    @Test("どの角でも、反対側の角の位置は変わらない。縦横比を保つとき、結果の縦横比は、元と同じ")
    func anchorStaysAndAspectIsExact() {
        for corner in ItemHandles.Corner.allCases {
            let anchor = corner.opposite.point(in: original)
            let grabbed = corner.point(in: original)
            let pointer = CGPoint(x: grabbed.x + (grabbed.x > anchor.x ? 30 : -30), y: grabbed.y + (grabbed.y > anchor.y ? 20 : -20))
            for keep in [true, false] {
                let box = ItemHandles.box(original: original, corner: corner, pointer: pointer, keepAspect: keep)
                #expect(corner.opposite.point(in: box) == anchor, "\(corner) keepAspect=\(keep)")
                #expect(box.width > original.width && box.height > original.height)
            }
            let kept = ItemHandles.box(original: original, corner: corner, pointer: CGPoint(x: 37, y: 411), keepAspect: true)
            #expect(abs(kept.width / kept.height - 2) < 1e-9, "\(corner)")
        }
    }

    @Test("保たない：ポインタのとおりに、縦横を別々に変える。反対側の角を越えると、反対向きに伸びる")
    func freeResizeAndCrossing() {
        #expect(ItemHandles.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 400, y: 130), keepAspect: false) == CGRect(x: 100, y: 100, width: 300, height: 30))
        #expect(ItemHandles.box(original: original, corner: .topLeft, pointer: CGPoint(x: 400, y: 260), keepAspect: false) == CGRect(x: 300, y: 200, width: 100, height: 60))
    }

    @Test("短い辺は下限を下回らない（縦横比を保つときは、保ったまま大きくする）。下限は、画像 8 pt・円と四角 1 pt")
    func minimumSide() {
        let atAnchor = ItemHandles.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 100, y: 100), keepAspect: true)
        #expect(atAnchor.height == ItemHandles.imageMinSide && atAnchor.width == 2 * ItemHandles.imageMinSide)
        let free = ItemHandles.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 101, y: 300), keepAspect: false)
        #expect(free.width == ItemHandles.imageMinSide && free.height == 200)
        let shape = ItemHandles.box(original: original, corner: .bottomRight, pointer: CGPoint(x: 100, y: 100), keepAspect: false, minSide: ItemHandles.shapeMinSide)
        #expect(shape.size == CGSize(width: 1, height: 1))
    }

    @Test("元の短い辺が下限未満の要素は、触っただけで跳ねない。ポインタが掴んだ角のままなら、元の枠そのもの")
    func tinyOriginalAndNoMovement() {
        let wide = CGRect(x: 10, y: 10, width: 336, height: 0.336)   // 1000:1
        let odd = CGRect(x: 100.3, y: 100.3, width: 200.7, height: 100.1)
        for corner in ItemHandles.Corner.allCases {
            #expect(ItemHandles.box(original: wide, corner: corner, pointer: corner.point(in: wide), keepAspect: true) == wide)
            for keep in [true, false] {
                #expect(ItemHandles.box(original: odd, corner: corner, pointer: corner.point(in: odd), keepAspect: keep) == odd)
            }
        }
        let slightly = ItemHandles.box(original: wide, corner: .bottomRight, pointer: CGPoint(x: wide.maxX + 10, y: wide.maxY), keepAspect: true)
        #expect(slightly.width < 400 && abs(slightly.width / slightly.height - 1000) < 1e-6)
    }

    // MARK: 回した枠

    @Test("回した枠：反対側の角は、画面の上で動かず、掴んだ角は、ポインタの位置に来る。回転角は変わらない")
    func rotatedBoxKeepsTheAnchorOnScreen() {
        let center = CGPoint(x: original.midX, y: original.midY)
        for degrees in [30.0, 90.0, -45.0, 170.0] {
            let angle = CGFloat(degrees) * .pi / 180
            for corner in ItemHandles.Corner.allCases {
                let anchorWorld = ItemHandles.rotate(corner.opposite.point(in: original), about: center, by: angle)
                let grabbedWorld = ItemHandles.rotate(corner.point(in: original), about: center, by: angle)
                // 掴んだ角を、枠の外向きに（回した向きで）広げる
                let out = ItemHandles.rotate(CGPoint(x: grabbedWorld.x + 40, y: grabbedWorld.y + 25), about: grabbedWorld, by: 0)
                let local = ItemHandles.rotate(out, about: center, by: -angle)
                let anchorLocal = corner.opposite.point(in: original), grabbedLocal = corner.point(in: original)
                // 外向きに広がる点（ローカルで、反対側の角から見て、掴んだ角より遠く）だけを試す
                guard (local.x - anchorLocal.x) * (grabbedLocal.x - anchorLocal.x) > 0, (local.y - anchorLocal.y) * (grabbedLocal.y - anchorLocal.y) > 0,
                      abs(local.x - anchorLocal.x) > abs(grabbedLocal.x - anchorLocal.x), abs(local.y - anchorLocal.y) > abs(grabbedLocal.y - anchorLocal.y) else { continue }
                let box = ItemHandles.box(original: original, rotation: angle, corner: corner, pointer: out, keepAspect: false)
                let newCenter = CGPoint(x: box.midX, y: box.midY)
                let anchorAfter = ItemHandles.rotate(corner.opposite.point(in: box), about: newCenter, by: angle)
                let cornerAfter = ItemHandles.rotate(corner.point(in: box), about: newCenter, by: angle)
                #expect(near(anchorAfter, anchorWorld, 1e-6), "anchor \(corner) \(degrees)°")
                #expect(near(cornerAfter, out, 1e-6), "corner \(corner) \(degrees)°")
            }
        }
    }

    @Test("回した枠で、縦横比を保つ：結果の縦横比は、元と同じ。反対側の角は動かない")
    func rotatedBoxKeepsAspect() {
        let angle: CGFloat = .pi / 6
        let center = CGPoint(x: original.midX, y: original.midY)
        let anchorWorld = ItemHandles.rotate(original.origin, about: center, by: angle)   // 左上
        let pointer = ItemHandles.rotate(CGPoint(x: 420, y: 330), about: center, by: angle)
        let box = ItemHandles.box(original: original, rotation: angle, corner: .bottomRight, pointer: pointer, keepAspect: true)
        #expect(abs(box.width / box.height - 2) < 1e-9)
        let anchorAfter = ItemHandles.rotate(box.origin, about: CGPoint(x: box.midX, y: box.midY), by: angle)
        #expect(near(anchorAfter, anchorWorld, 1e-6))
    }

    @Test("回していない（0°）ときの結果は、回転の計算を通さない場合と、ぴったり同じ")
    func zeroRotationIsExact() {
        let a = ItemHandles.box(original: original, rotation: 0, corner: .bottomRight, pointer: CGPoint(x: 333.3, y: 222.2), keepAspect: false)
        #expect(a == CGRect(x: 100, y: 100, width: 233.3, height: 122.2) || abs(a.width - 233.3) < 1e-9 && abs(a.height - 122.2) < 1e-9)
        #expect(a.origin == original.origin)
    }

    @Test("置き直し：反対側の角を固定して、指定の大きさの枠にする（元の向きに伸びる）。回していても、反対側の角は画面で動かない")
    func anchoredBoxKeepsTheAnchor() {
        let size = CGSize(width: 50, height: 20)
        for corner in ItemHandles.Corner.allCases {
            let plain = ItemHandles.anchoredBox(original: original, corner: corner, size: size)
            #expect(plain.size == size)
            #expect(corner.opposite.point(in: plain) == corner.opposite.point(in: original))
            let angle: CGFloat = 0.7
            let center = CGPoint(x: original.midX, y: original.midY)
            let anchorWorld = ItemHandles.rotate(corner.opposite.point(in: original), about: center, by: angle)
            let rotated = ItemHandles.anchoredBox(original: original, rotation: angle, corner: corner, size: size)
            let after = ItemHandles.rotate(corner.opposite.point(in: rotated), about: CGPoint(x: rotated.midX, y: rotated.midY), by: angle)
            #expect(rotated.size == size && near(after, anchorWorld, 1e-6), "\(corner)")
        }
    }

    // MARK: 文字の等倍

    /// 文字の幅は、大きさの 5 倍、高さは 2 倍とする、測り方の代わり。
    private let measure: (CGFloat) -> CGSize = { CGSize(width: 5 * $0, height: 2 * $0) }

    @Test("文字：枠の倍率で、文字の大きさが変わる。反対側の角は動かず、枠は、その大きさで描いた大きさになる")
    func textScales() {
        let box = CGRect(x: 100, y: 100, width: 90, height: 36)   // 18 pt
        let r = ItemHandles.scaledText(original: box, rotation: 0, corner: .bottomRight, pointer: CGPoint(x: 280, y: 172), fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(r.fontSize == 36 && r.box == CGRect(x: 100, y: 100, width: 180, height: 72))
        let small = ItemHandles.scaledText(original: box, rotation: 0, corner: .topLeft, pointer: CGPoint(x: 145, y: 118), fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(small.fontSize == 9 && small.box == CGRect(x: 190 - 45, y: 136 - 18, width: 45, height: 18))   // 右下の角（190, 136）が動かない
    }

    @Test("文字：範囲（8〜200）で止まる。ポインタが掴んだ角のままなら、そのまま")
    func textScaleLimitsAndIdentity() {
        let box = CGRect(x: 100, y: 100, width: 90, height: 36)
        let big = ItemHandles.scaledText(original: box, rotation: 0, corner: .bottomRight, pointer: CGPoint(x: 5000, y: 5000), fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(big.fontSize == 200)
        let tiny = ItemHandles.scaledText(original: box, rotation: 0, corner: .bottomRight, pointer: CGPoint(x: 101, y: 101), fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(tiny.fontSize == 8)
        let same = ItemHandles.scaledText(original: box, rotation: 0, corner: .bottomRight, pointer: CGPoint(x: 190, y: 136), fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(same.box == box && same.fontSize == 18)
        let atMax = ItemHandles.scaledText(original: CGRect(x: 0, y: 0, width: 1000, height: 400), rotation: 0, corner: .bottomRight, pointer: CGPoint(x: 3000, y: 1200), fontSize: 200, fontRange: 8...200, measure: measure)
        #expect(atMax.fontSize == 200 && atMax.box == CGRect(x: 0, y: 0, width: 1000, height: 400))   // 大きさが変わらなければ、枠も変えない
    }

    @Test("回した文字：反対側の角は、画面の上で動かない")
    func rotatedTextKeepsTheAnchor() {
        let box = CGRect(x: 100, y: 100, width: 90, height: 36)
        let angle: CGFloat = .pi / 3
        let center = CGPoint(x: box.midX, y: box.midY)
        let anchorWorld = ItemHandles.rotate(box.origin, about: center, by: angle)
        let pointer = ItemHandles.rotate(CGPoint(x: 280, y: 172), about: center, by: angle)
        let r = ItemHandles.scaledText(original: box, rotation: angle, corner: .bottomRight, pointer: pointer, fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(r.fontSize > 18)
        #expect(near(ItemHandles.rotate(r.box.origin, about: CGPoint(x: r.box.midX, y: r.box.midY), by: angle), anchorWorld, 1e-6))
    }

    // MARK: 取っ手の位置と掴める範囲

    @Test("回転の取っ手：上辺の中央から 24 pt 上。キャンバスの外（縁から 8 pt 以内）になるときは、下辺の中央から 24 pt 下")
    func rotationHandlePlacement() {
        let normal = ItemHandles.rotationHandle(of: .box(original, rotation: 0), canvas: canvasRect)
        #expect(near(normal.stem, CGPoint(x: 200, y: 100)) && near(normal.handle, CGPoint(x: 200, y: 76)))
        let top = ItemHandles.rotationHandle(of: .box(CGRect(x: 100, y: 10, width: 200, height: 100), rotation: 0), canvas: canvasRect)
        #expect(near(top.stem, CGPoint(x: 200, y: 110)) && near(top.handle, CGPoint(x: 200, y: 134)))
        let rotated = ItemHandles.rotationHandle(of: .box(original, rotation: .pi / 2), canvas: canvasRect)   // 90°：上が右へ回る
        #expect(near(rotated.handle, CGPoint(x: 200 + 50 + 24, y: 150)))
        let line = ItemHandles.rotationHandle(of: .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200)), canvas: canvasRect)
        #expect(near(line.handle, CGPoint(x: 200, y: 76)))
        let pen = ItemHandles.rotationHandle(of: .stroke(frame: CGRect(x: 10, y: 30, width: 100, height: 40)), canvas: canvasRect)
        #expect(near(pen.handle, CGPoint(x: 60, y: 6)) == false && near(pen.handle, CGPoint(x: 60, y: 94)))   // 上（y=6）は縁に近すぎるので、下
    }

    @Test("取っ手の一覧：枠は四隅と回転、直線は両端と回転、ペンは回転だけ。短い辺が 4 pt 未満の枠は、回転だけ")
    func handleLists() {
        #expect(ItemHandles.handles(of: .box(original, rotation: 0)).count == 5)
        #expect(ItemHandles.handles(of: .line(from: .zero, to: CGPoint(x: 9, y: 9))) == [.lineStart, .lineEnd, .rotate])
        #expect(ItemHandles.handles(of: .stroke(frame: CGRect(x: 0, y: 0, width: 5, height: 5))) == [.rotate])
        #expect(ItemHandles.handles(of: .box(CGRect(x: 0, y: 0, width: 3.9, height: 50), rotation: 0)) == [.rotate])
        #expect(ItemHandles.handles(of: .box(CGRect(x: 0, y: 0, width: 4, height: 4), rotation: 0)).count == 5)
    }

    @Test("枠の取っ手：角の近くだけ。中や辺の途中は掴めない。回した枠では、回した角の位置で掴む")
    func cornerHitTest() {
        let shape = ItemHandles.Shape.box(original, rotation: 0)
        #expect(ItemHandles.handle(at: CGPoint(x: 103, y: 96), in: shape, canvas: canvasRect) == .corner(.topLeft))
        #expect(ItemHandles.handle(at: CGPoint(x: 297, y: 203), in: shape, canvas: canvasRect) == .corner(.bottomRight))
        #expect(ItemHandles.handle(at: CGPoint(x: 200, y: 150), in: shape, canvas: canvasRect) == nil)
        #expect(ItemHandles.handle(at: CGPoint(x: 200, y: 100), in: shape, canvas: canvasRect) == nil)
        let rotated = ItemHandles.Shape.box(original, rotation: .pi / 2)   // 右下の角は、画面の (150, 250) に来る
        #expect(ItemHandles.handle(at: CGPoint(x: 150, y: 250), in: rotated, canvas: canvasRect) == .corner(.bottomRight))
        #expect(ItemHandles.handle(at: CGPoint(x: 300, y: 200), in: rotated, canvas: canvasRect) == nil)   // 回る前の位置は、もう角ではない
        let tiny = ItemHandles.Shape.box(CGRect(x: 100, y: 100, width: 8, height: 8), rotation: 0)   // 取っ手同士が重なる小ささ
        #expect(ItemHandles.handle(at: CGPoint(x: 107, y: 107), in: tiny, canvas: canvasRect) == .corner(.bottomRight))
        #expect(ItemHandles.handle(at: CGPoint(x: 101, y: 101), in: tiny, canvas: canvasRect) == .corner(.topLeft))
    }

    @Test("回転の取っ手：上も下も収まらないほど高い枠では、縁の内側へ寄せる（キャンバスの外に出て、届かなくならない）")
    func rotationHandleStaysReachable() {
        let tall = ItemHandles.Shape.box(CGRect(x: 100, y: 5, width: 200, height: 312), rotation: 0)   // キャンバス（高さ 320）いっぱい
        let knob = ItemHandles.rotationHandle(of: tall, canvas: canvasRect).handle
        #expect(canvasRect.insetBy(dx: 8, dy: 8).contains(knob))
        #expect(ItemHandles.handle(at: knob, in: tall, canvas: canvasRect) == .rotate)
    }

    @Test("文字：反対側の角を越えると、倍率は 0 以下（下限の 8 pt）。元の向きに大きくならない")
    func textScaleDoesNotGrowWhenCrossing() {
        let box = CGRect(x: 100, y: 100, width: 90, height: 36)
        let measure: (CGFloat) -> CGSize = { CGSize(width: 5 * $0, height: 2 * $0) }
        let crossed = ItemHandles.scaledText(original: box, rotation: 0, corner: .bottomRight, pointer: CGPoint(x: 40, y: 60), fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(crossed.fontSize == 8)
        let crossedLocal = ItemHandles.rotate(CGPoint(x: 250, y: 200), about: CGPoint(x: box.midX, y: box.midY), by: .pi / 3)   // 回る前の枠で、右下の角（反対側）より、右下
        let rotatedCrossed = ItemHandles.scaledText(original: box, rotation: .pi / 3, corner: .topLeft, pointer: crossedLocal, fontSize: 18, fontRange: 8...200, measure: measure)
        #expect(rotatedCrossed.fontSize == 8)
    }

    @Test("-180° は 180° と出る（丸め誤差で、-π のすぐ上になっても）")
    func halfTurnIsPositive() {
        #expect(abs(ItemHandles.normalized(-.pi + 1e-12) - .pi) < 1e-9)
        #expect(ItemEncoder.degrees(-.pi + 1e-12).doubleValue == 180)
        #expect(ItemEncoder.degrees(-.pi / 2).doubleValue == -90)
    }

    @Test("小さい枠：内側の取っ手の範囲は、辺の 1/4 まで。中央は掴んで動かせる")
    func smallBoxCenterIsNotAHandle() {
        let small = ItemHandles.Shape.box(CGRect(x: 100, y: 100, width: 12, height: 12), rotation: 0)
        #expect(ItemHandles.handle(at: CGPoint(x: 106, y: 106), in: small, canvas: canvasRect) == nil)
        #expect(ItemHandles.handle(at: CGPoint(x: 102, y: 102), in: small, canvas: canvasRect) == .corner(.topLeft))
        #expect(ItemHandles.handle(at: CGPoint(x: 94, y: 94), in: small, canvas: canvasRect) == .corner(.topLeft))
    }

    @Test("回転の取っ手は、先に掴める（回転の取っ手の位置は、ほかの取っ手より優先）。ペンは、回転の取っ手だけ")
    func rotationHandleIsHitFirst() {
        let shape = ItemHandles.Shape.box(original, rotation: 0)
        #expect(ItemHandles.handle(at: CGPoint(x: 200, y: 76), in: shape, canvas: canvasRect) == .rotate)
        #expect(ItemHandles.handle(at: CGPoint(x: 204, y: 80), in: shape, canvas: canvasRect) == .rotate)
        #expect(ItemHandles.handle(at: CGPoint(x: 200, y: 60), in: shape, canvas: canvasRect) == nil)
        let pen = ItemHandles.Shape.stroke(frame: CGRect(x: 100, y: 100, width: 100, height: 50))
        #expect(ItemHandles.handle(at: CGPoint(x: 150, y: 76), in: pen, canvas: canvasRect) == .rotate)
        #expect(ItemHandles.handle(at: CGPoint(x: 100, y: 100), in: pen, canvas: canvasRect) == nil)
    }

    @Test("直線の取っ手：両端の近くだけ。中は掴めない。短い直線では、内側へ狭める。外側は 7 pt")
    func lineHitTest() {
        let long = ItemHandles.Shape.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        #expect(ItemHandles.handle(at: CGPoint(x: 103, y: 97), in: long, canvas: canvasRect) == .lineStart)
        #expect(ItemHandles.handle(at: CGPoint(x: 297, y: 204), in: long, canvas: canvasRect) == .lineEnd)
        #expect(ItemHandles.handle(at: CGPoint(x: 200, y: 150), in: long, canvas: canvasRect) == nil)
        let short = ItemHandles.Shape.line(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 112, y: 200))   // 長さ 12：内側は 3
        #expect(ItemHandles.handle(at: CGPoint(x: 106, y: 200), in: short, canvas: canvasRect) == nil)
        #expect(ItemHandles.handle(at: CGPoint(x: 102, y: 200), in: short, canvas: canvasRect) == .lineStart)
        #expect(ItemHandles.handle(at: CGPoint(x: 95, y: 200), in: short, canvas: canvasRect) == .lineStart)
        #expect(ItemHandles.handle(at: CGPoint(x: 91, y: 200), in: short, canvas: canvasRect) == nil)
        #expect(ItemHandles.handle(at: CGPoint(x: 50, y: 50), in: .line(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5)), canvas: canvasRect) == nil)
    }

    // MARK: 直線

    @Test("直線：掴んだ端だけが動く。長さが 1 pt 未満になる位置では nil。掴んだ位置のままなら、元のまま。取っ手が形に合わなければ nil")
    func lineEndpoints() {
        let line = ItemHandles.Shape.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        #expect(ItemHandles.resized(line, handle: .lineStart, pointer: CGPoint(x: 50, y: 20), keepAspect: false, minSide: 0) == .line(from: CGPoint(x: 50, y: 20), to: CGPoint(x: 300, y: 200)))
        #expect(ItemHandles.resized(line, handle: .lineEnd, pointer: CGPoint(x: 400, y: 10), keepAspect: true, minSide: 0) == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 10)))
        #expect(ItemHandles.resized(line, handle: .lineEnd, pointer: CGPoint(x: 100.5, y: 100), keepAspect: false, minSide: 0) == nil)
        #expect(ItemHandles.resized(line, handle: .lineEnd, pointer: CGPoint(x: 300, y: 200), keepAspect: false, minSide: 0) == line)
        #expect(ItemHandles.resized(.box(original, rotation: 0), handle: .lineEnd, pointer: .zero, keepAspect: false, minSide: 1) == nil)
        #expect(ItemHandles.resized(line, handle: .corner(.topLeft), pointer: .zero, keepAspect: false, minSide: 1) == nil)
        #expect(ItemHandles.resized(line, handle: .rotate, pointer: .zero, keepAspect: false, minSide: 1) == nil)
    }
}

@Suite("要素の回転：文書・描画・書き出し（A30）")
struct ItemRotationDocumentTests {
    @Test("回した要素の bounds は、回したあとの外接する範囲（掴める範囲・動かせる範囲は、これで決まる）")
    func rotatedBounds() {
        let rect = rectItem(CGRect(x: 0, y: 0, width: 100, height: 10), rotation: .pi / 2)   // 線の太さ 4：外側へ 2 pt
        let b = rect.bounds
        #expect(abs(b.midX - 50) < 1e-9 && abs(b.midY - 5) < 1e-9)
        #expect(abs(b.width - 14) < 1e-9 && abs(b.height - 104) < 1e-9)
        #expect(rect.unrotatedBounds == CGRect(x: -2, y: -2, width: 104, height: 14))
        #expect(rectItem(CGRect(x: 0, y: 0, width: 100, height: 10)).bounds == rect.unrotatedBounds)
        let moved = rect.translated(by: CGSize(width: 10, height: 20))
        #expect(moved.rotation == rect.rotation && abs(moved.bounds.minX - (b.minX + 10)) < 1e-9)
    }

    @Test("大きさを変えられる対象：ペン（外接する範囲だけ）・文字（等倍）も、取っ手の対象になる")
    func targets() {
        let doc = Document().appending(contentsOf: [penItem([CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 60)]), textItem(at: CGPoint(x: 5, y: 5)),
                                                     imageItem(CGRect(x: 0, y: 0, width: 40, height: 30)), rectItem(CGRect(x: 0, y: 0, width: 40, height: 30), rotation: 0.5),
                                                     ellipseItem(CGRect(x: 0, y: 0, width: 40, height: 30)), lineItem(.zero, CGPoint(x: 5, y: 5))])
        #expect(doc.resizeTarget(at: 0)?.kind == .pen && doc.resizeTarget(at: 0)?.shape == .stroke(frame: CGRect(x: 10, y: 20, width: 40, height: 40)))
        #expect(doc.resizeTarget(at: 1)?.kind == .text && doc.resizeTarget(at: 1)?.keepsAspect == true)
        #expect(doc.resizeTarget(at: 2)?.kind == .image && doc.resizeTarget(at: 2)?.minSide == ItemHandles.imageMinSide)
        #expect(doc.resizeTarget(at: 3)?.shape == .box(CGRect(x: 0, y: 0, width: 40, height: 30), rotation: 0.5) && doc.resizeTarget(at: 3)?.keepsAspect == false)
        #expect(doc.resizeTarget(at: 4)?.kind == .ellipse && doc.resizeTarget(at: 5)?.kind == .line)
        #expect(doc.resizeTarget(at: 6) == nil && doc.resizeTarget(at: -1) == nil)
        #expect(Document().appending(penItem([])).resizeTarget(at: 0) == nil)   // 点のないペン
    }

    @Test("回す：円・四角・画像・文字は回転角が変わる（枠は同じ）。直線・ペンは点が回る。元の文書は変わらない")
    func rotating() throws {
        let box = CGRect(x: 100, y: 100, width: 200, height: 100)
        let doc = Document().appending(contentsOf: [rectItem(box), penItem([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 150)]),
                                                     lineItem(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)), textItem(at: CGPoint(x: 5, y: 5))])
        let turned = try #require(doc.rotating(itemAt: 0, by: .pi / 2))
        #expect(abs(turned.items[0].rotation - .pi / 2) < 1e-12 && turned.resizeTarget(at: 0)?.shape == .box(box, rotation: turned.items[0].rotation))
        #expect(doc.items[0].rotation == 0)
        let twice = try #require(turned.rotating(itemAt: 0, by: .pi))
        #expect(abs(twice.items[0].rotation + .pi / 2) < 1e-12)   // 270° は、-90°
        // ペン：外接する範囲の中心 (150, 125) を軸に、時計回り 90°。(200, 100) は (175, 175) へ
        let pen = try #require(doc.rotating(itemAt: 1, by: .pi / 2))
        guard case .pen(let points) = pen.items[1].content else { Issue.record("ペンでない"); return }
        #expect(near(points[1].point, CGPoint(x: 175, y: 175), 1e-9) && near(points[0].point, CGPoint(x: 175, y: 75), 1e-9) && points.allSatisfy { $0.pressure == 1 })
        #expect(pen.items[1].rotation == 0)
        // 直線：中点 (200, 100) を軸に 90°：(100,100) → (200,0)、(300,100) → (200,200)
        let line = try #require(doc.rotating(itemAt: 2, by: .pi / 2))
        guard case .line(let a, let b) = line.items[2].content else { Issue.record("直線でない"); return }
        #expect(near(a, CGPoint(x: 200, y: 0), 1e-9) && near(b, CGPoint(x: 200, y: 200), 1e-9))
        #expect(doc.rotating(itemAt: 9, by: 1) == nil)
    }

    @Test("変わったか：180° 回したペン（外接する範囲が同じ）も、回転角だけ変わった図形も、変わったことになる。同じなら変わらない")
    func hasChanged() throws {
        let doc = Document().appending(contentsOf: [penItem([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)]), rectItem(CGRect(x: 100, y: 100, width: 100, height: 100))])
        let pen180 = try #require(doc.rotating(itemAt: 0, by: .pi))
        #expect(pen180.items[0].bounds == doc.items[0].bounds)                       // 外接する範囲は、同じ
        #expect(pen180.hasChangedItem(at: 0, since: doc))                            // それでも、変わった
        let rect180 = try #require(doc.rotating(itemAt: 1, by: .pi))
        #expect(rect180.hasChangedItem(at: 1, since: doc))
        #expect(!doc.hasChangedItem(at: 0, since: doc) && !doc.hasChangedItem(at: 5, since: doc))
        let moved = try #require(doc.translatingItem(at: 1, by: CGSize(width: 3, height: 0), keepingGrabAreaIn: canvasRect))
        #expect(moved.hasChangedItem(at: 1, since: doc))
    }

    @Test("文字の大きさと枠を、あわせて差し替える。ペンには、形を差し替えられない")
    func applyingText() throws {
        let doc = Document().appending(contentsOf: [textItem(at: CGPoint(x: 10, y: 10)), penItem([CGPoint(x: 1, y: 1)])])
        let box = CGRect(x: 10, y: 10, width: 200, height: 40)
        let changed = try #require(doc.applying(.box(box, rotation: 0.3), fontSize: 30, toItemAt: 0))
        #expect(changed.items[0].size == 30 && changed.items[0].rotation == 0.3 && changed.resizeTarget(at: 0)?.shape == .box(box, rotation: 0.3))
        #expect(doc.applying(.box(box, rotation: 0), toItemAt: 1) == nil)
    }

    @Test("回した四角の描画：縦にした細い四角の、上の端が塗られ、元の横の端は塗られない")
    func rotatedRenderIsRotated() throws {
        let item = Item(content: .rect(CGRect(x: 100, y: 100, width: 100, height: 20)), color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), size: 2, filled: true, rotation: .pi / 2)
        let data = try #require(CanvasRenderer.pngData(Document(items: [item]), size: CGSize(width: 480, height: 320), transparent: false))
        let rep = try #require(NSBitmapImageRep(data: data))
        func isRed(_ x: Int, _ y: Int) throws -> Bool {   // 2 倍の画素
            let c = try #require(rep.colorAt(x: x * 2, y: y * 2)?.usingColorSpace(.sRGB))
            return c.redComponent > 0.9 && c.greenComponent < 0.2
        }
        #expect(try isRed(150, 70))      // 回して縦になった四角の、上の部分（中心 (150,110) から 40 上）
        #expect(try isRed(150, 150))
        #expect(try !isRed(105, 110))    // 回す前の、左の端
        #expect(try !isRed(195, 110))
    }

    @Test("get の rotate：円・四角・画像・文字だけに、度で出る。時計回りが正。ペン・直線には無い")
    func encodesRotate() {
        func rotate(_ item: Item) -> Double? { (ItemEncoder.json(item, index: 0)["rotate"] as? NSDecimalNumber)?.doubleValue }
        #expect(rotate(rectItem(CGRect(x: 0, y: 0, width: 10, height: 10), rotation: .pi / 2)) == 90)
        #expect(rotate(rectItem(CGRect(x: 0, y: 0, width: 10, height: 10), rotation: -.pi / 4)) == -45)
        #expect(rotate(rectItem(CGRect(x: 0, y: 0, width: 10, height: 10))) == 0)
        #expect(abs((rotate(textItem(at: .zero, rotation: 1)) ?? 0) - 57.296) < 1e-9, "got \(String(describing: rotate(textItem(at: .zero, rotation: 1))))")
        var image = imageItem(CGRect(x: 0, y: 0, width: 10, height: 10)); image.rotation = .pi
        #expect(rotate(image) == 180)
        #expect(rotate(ellipseItem(CGRect(x: 0, y: 0, width: 10, height: 10))) == 0)
        #expect(ItemEncoder.json(lineItem(.zero, CGPoint(x: 5, y: 5)), index: 0)["rotate"] == nil)
        #expect(ItemEncoder.json(penItem([.zero]), index: 0)["rotate"] == nil)
    }
}

@Suite("取っ手：キャンバスの操作（A29〜A31）")
struct ItemHandlesCanvasTests {
    private func canvas(_ items: [Item]) -> CanvasView {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.appendFromAgent(items)
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
    private func click(_ c: CanvasView, _ p: CGPoint) throws { try down(c, p); try up(c, p) }
    private func dragFrom(_ c: CanvasView, _ a: CGPoint, to b: CGPoint, shift: Bool = false) throws {
        try down(c, a); try drag(c, b, shift: shift); try up(c, b)
    }

    private func shape(_ c: CanvasView, _ index: Int = 0) -> ItemHandles.Shape? { c.document.resizeTarget(at: index)?.shape }
    private func box(_ c: CanvasView, _ index: Int = 0) -> CGRect? {
        if case .box(let b, _)? = shape(c, index) { return b }
        return nil
    }
    private func rotation(_ c: CanvasView, _ index: Int = 0) -> CGFloat { c.document.items[index].rotation }

    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)   // 中心 (200, 150)。回転の取っ手は (200, 76)

    @Test("移動ツールで、どの要素をクリックしても選ばれる（ペン・文字も）。何もない所・ツールの切り替えで外れる")
    func selection() throws {
        let c = canvas([imageItem(CGRect(x: 20, y: 20, width: 80, height: 60)), rectItem(CGRect(x: 120, y: 20, width: 80, height: 60)),
                        ellipseItem(CGRect(x: 220, y: 20, width: 80, height: 60)), lineItem(CGPoint(x: 20, y: 200), CGPoint(x: 300, y: 260)),
                        penItem([CGPoint(x: 400, y: 20), CGPoint(x: 440, y: 60)]), textItem(at: CGPoint(x: 330, y: 150))])
        for (index, point) in [(0, CGPoint(x: 60, y: 50)), (1, CGPoint(x: 160, y: 50)), (2, CGPoint(x: 260, y: 50)), (3, CGPoint(x: 160, y: 230)),
                               (4, CGPoint(x: 420, y: 40)), (5, CGPoint(x: 345, y: 160))] {
            try click(c, point)
            #expect(c.selectedItem == index, "index \(index)")
        }
        try click(c, CGPoint(x: 20, y: 300)); #expect(c.selectedItem == nil)
        try click(c, CGPoint(x: 160, y: 50)); c.tool = .pen; #expect(c.selectedItem == nil)
    }

    @Test("回転の取っ手：掴んだだけでは回らない。時計回りが正で、中心の向きに追従する。取り消しの 1 段で、戻せて、やり直せる")
    func rotateRect() throws {
        let c = canvas([rectItem(rect)])
        try click(c, CGPoint(x: 200, y: 150))
        try click(c, CGPoint(x: 200, y: 76))                                   // 取っ手を押しただけ
        #expect(rotation(c) == 0)
        c.undo()
        #expect(c.document.items.isEmpty)                                       // 取り消しの段は、足した段だけ（回転の段は、無い）
        c.redo()
        try click(c, CGPoint(x: 200, y: 150))
        try down(c, CGPoint(x: 200, y: 76))
        try drag(c, CGPoint(x: 300, y: 150))                                    // 上 → 右：時計回りに 90°
        #expect(abs(rotation(c) - .pi / 2) < 1e-9)
        try drag(c, CGPoint(x: 200, y: 250))                                    // 下：180°
        #expect(abs(abs(rotation(c)) - .pi) < 1e-9)
        try up(c, CGPoint(x: 200, y: 250))
        #expect(box(c) == rect)                                                 // 元の枠は、変わらない
        c.undo()
        #expect(rotation(c) == 0)                                               // 1 回のドラッグが、1 段
        c.redo()
        #expect(abs(abs(rotation(c)) - .pi) < 1e-9)
    }

    @Test("Shift で 15° きざみ（回転角そのものが、15° の倍数）")
    func shiftSnaps() throws {
        let c = canvas([rectItem(rect)])
        try click(c, CGPoint(x: 200, y: 150))
        try dragFrom(c, CGPoint(x: 200, y: 76), to: CGPoint(x: 290, y: 100), shift: true)   // 向き -29° → 回転角 61° → 60°
        #expect(abs(rotation(c) - .pi / 3) < 1e-9)
        try dragFrom(c, ItemHandles.rotationHandle(of: shape(c)!, canvas: CGRect(x: 0, y: 0, width: 480, height: 320)).handle, to: CGPoint(x: 200, y: 20), shift: true)
        #expect(abs(rotation(c) / ItemHandles.snapAngle - (rotation(c) / ItemHandles.snapAngle).rounded()) < 1e-9)
    }

    @Test("ペン：点が回る（外接する範囲の中心が軸）。取り消しで戻る。大きさの取っ手は無い")
    func rotatePen() throws {
        let c = canvas([penItem([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 150)])])   // 枠の中心 (150, 125)。取っ手は (150, 76)
        try click(c, CGPoint(x: 150, y: 110))
        #expect(c.selectedItem == 0)
        try dragFrom(c, CGPoint(x: 150, y: 76), to: CGPoint(x: 250, y: 125))                                      // 90°
        guard case .pen(let points) = c.document.items[0].content else { Issue.record("ペンでない"); return }
        #expect(near(points[1].point, CGPoint(x: 175, y: 175), 1e-6))
        #expect(c.document.items[0].rotation == 0)
        try click(c, CGPoint(x: 100, y: 100))                                                                       // 回したあとの、角（元の枠の角）は、大きさの取っ手ではない
        c.undo()
        guard case .pen(let back) = c.document.items[0].content else { return }
        #expect(near(back[1].point, CGPoint(x: 200, y: 100), 1e-6))
    }

    @Test("直線：中点を軸に回る。両端の取っ手は、回したあとの端に来て、掴んだ端だけが動く")
    func rotateLine() throws {
        let c = canvas([lineItem(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100))])
        try click(c, CGPoint(x: 200, y: 100))
        try dragFrom(c, CGPoint(x: 200, y: 76), to: CGPoint(x: 300, y: 100))                                        // 90°
        #expect(shape(c) == .line(from: CGPoint(x: 200, y: 0), to: CGPoint(x: 200, y: 200)) || {
            if case .line(let a, let b)? = shape(c) { return near(a, CGPoint(x: 200, y: 0), 1e-6) && near(b, CGPoint(x: 200, y: 200), 1e-6) }
            return false
        }())
        try dragFrom(c, CGPoint(x: 200, y: 200), to: CGPoint(x: 260, y: 200))                                       // 終点だけ動く
        guard case .line(let a, let b)? = shape(c) else { Issue.record("直線でない"); return }
        #expect(near(a, CGPoint(x: 200, y: 0), 1e-6) && near(b, CGPoint(x: 260, y: 200), 1e-6))
    }

    @Test("回した四角の角の取っ手：回した角の位置で掴み、反対側の角は画面で動かない。回転角は変わらない")
    func resizeRotatedRect() throws {
        let c = canvas([rectItem(rect, rotation: .pi / 2)])       // 右下の角は (150, 250)、左上の角は (250, 50)
        try click(c, CGPoint(x: 200, y: 150))
        try dragFrom(c, CGPoint(x: 150, y: 250), to: CGPoint(x: 150, y: 300))
        let target = try #require(c.document.resizeTarget(at: 0))
        #expect(abs(rotation(c) - .pi / 2) < 1e-9)
        let canvasRect = CGRect(x: 0, y: 0, width: 480, height: 320)
        let anchor = try #require(ItemHandles.point(of: .corner(.topLeft), in: target.shape, canvas: canvasRect))
        let grabbed = try #require(ItemHandles.point(of: .corner(.bottomRight), in: target.shape, canvas: canvasRect))
        #expect(near(anchor, CGPoint(x: 250, y: 50), 1e-6))
        #expect(near(grabbed, CGPoint(x: 150, y: 300), 1e-6))
        c.undo()
        #expect(box(c) == rect && abs(rotation(c) - .pi / 2) < 1e-9)
    }

    @Test("文字：角の取っ手で、常に等倍（fontSize が変わり、反対側の角が動かない。Shift は効かない）。取り消しで戻る")
    func scaleText() throws {
        let item = textItem("Hello", at: CGPoint(x: 100, y: 100))
        let c = canvas([item])
        let original = try #require(box(c))
        try click(c, CGPoint(x: original.midX, y: original.midY))
        // 横へ 3 倍、縦は元のまま：自由なら 3:1 になる。等倍なら、横の倍率（3 倍）に揃う。Shift を押しても、同じ
        let end = CGPoint(x: original.minX + original.width * 3, y: original.maxY)
        try dragFrom(c, CGPoint(x: original.maxX, y: original.maxY), to: end, shift: true)
        let scaled = c.document.items[0]
        #expect(scaled.size > 52 && scaled.size < 56, "fontSize=\(scaled.size)")
        let after = try #require(box(c))
        #expect(after.origin == original.origin)
        #expect(abs(after.width / after.height - original.width / original.height) < 0.25, "original=\(original) after=\(after)")   // 縦横比は、ほぼ保たれる（文字の大きさで整数に丸まる）
        c.undo()
        #expect(c.document.items[0].size == 18 && box(c) == original)
    }

    @Test("回した文字も、角の取っ手で大きさが変わり、反対側の角は画面で動かない")
    func scaleRotatedText() throws {
        let c = canvas([textItem("Hello", at: CGPoint(x: 100, y: 100), rotation: .pi / 6)])
        let original = try #require(box(c))
        let center = CGPoint(x: original.midX, y: original.midY)
        let canvasRect = CGRect(x: 0, y: 0, width: 480, height: 320)
        let shapeBefore = try #require(shape(c))
        let anchorBefore = try #require(ItemHandles.point(of: .corner(.topLeft), in: shapeBefore, canvas: canvasRect))
        let grabbed = ItemHandles.rotate(CGPoint(x: original.maxX, y: original.maxY), about: center, by: .pi / 6)
        try click(c, center)
        let pointer = ItemHandles.rotate(CGPoint(x: original.minX + original.width * 2, y: original.minY + original.height * 2), about: center, by: .pi / 6)
        try dragFrom(c, grabbed, to: pointer)
        #expect(c.document.items[0].size > 30)
        let shapeAfter = try #require(shape(c))
        let anchorAfter = try #require(ItemHandles.point(of: .corner(.topLeft), in: shapeAfter, canvas: canvasRect))
        #expect(near(anchorBefore, anchorAfter, 1e-6))
    }

    @Test("文字は、範囲（8〜200）で止まる")
    func textRange() throws {
        let c = canvas([textItem("Hello", at: CGPoint(x: 20, y: 20))])
        let original = try #require(box(c))
        try click(c, CGPoint(x: original.midX, y: original.midY))
        try dragFrom(c, CGPoint(x: original.maxX, y: original.maxY), to: CGPoint(x: 470, y: 310))
        #expect(c.document.items[0].size <= 200)
        let current = try #require(shape(c))
        let corner = try #require(ItemHandles.point(of: .corner(.bottomRight), in: current, canvas: CGRect(x: 0, y: 0, width: 480, height: 320)))
        try dragFrom(c, corner, to: CGPoint(x: 21, y: 21))
        #expect(c.document.items[0].size == 8)
    }

    @Test("上が縁に近い要素は、回転の取っ手が下に出て、そこで回せる")
    func rotationHandleBelowAtTheTop() throws {
        let top = CGRect(x: 100, y: 10, width: 200, height: 100)
        let c = canvas([rectItem(top)])
        try click(c, CGPoint(x: 200, y: 60))
        try dragFrom(c, CGPoint(x: 200, y: 134), to: CGPoint(x: 300, y: 60))       // 下側の取っ手（中心から見て真下）を、右へ：反時計回り 90°
        #expect(abs(rotation(c) + .pi / 2) < 1e-9)
    }

    @Test("選ばれた要素の回転の取っ手は、上に重なる別の要素より先に掴める。回していない要素の外の、何もない所は、掴めない")
    func rotationHandleComesFirst() throws {
        let c = canvas([rectItem(rect), rectItem(CGRect(x: 180, y: 60, width: 40, height: 40))])    // 後ろの四角の取っ手 (200,76) に、手前の四角が重なる
        try click(c, CGPoint(x: 120, y: 150))
        #expect(c.selectedItem == 0)
        try dragFrom(c, CGPoint(x: 200, y: 76), to: CGPoint(x: 300, y: 150))
        #expect(abs(rotation(c, 0) - .pi / 2) < 1e-9 && rotation(c, 1) == 0)
        #expect(c.document.items[1].bounds == CGRect(x: 180, y: 60, width: 40, height: 40).insetBy(dx: -2, dy: -2))
    }

    @Test("ドラッグの途中で、エージェントが足した要素は残る。取り消しで、回す前に戻る")
    func agentAppendDuringRotate() throws {
        let c = canvas([rectItem(rect)])
        try click(c, CGPoint(x: 200, y: 150))
        try down(c, CGPoint(x: 200, y: 76))
        try drag(c, CGPoint(x: 300, y: 150))
        c.appendFromAgent([rectItem(CGRect(x: 10, y: 10, width: 20, height: 20))])
        try drag(c, CGPoint(x: 200, y: 250))
        try up(c, CGPoint(x: 200, y: 250))
        #expect(c.document.items.count == 2 && abs(abs(rotation(c)) - .pi) < 1e-9)
        c.undo()
        #expect(c.document.items.count == 2 && rotation(c) == 0)
    }

    @Test("回した要素も、動かせて、クリアでき、書き出しに取っ手が入らない。回転の取っ手のあるペン・文字でも、書き出しは同じ")
    func rotatedItemsMoveAndExport() throws {
        for item in [penItem([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 160)]), textItem(at: CGPoint(x: 100, y: 100)), rectItem(rect, rotation: 0.4)] {
            let c = canvas([item])
            let before = try #require(c.renderPNG())
            let bounds = c.document.items[0].bounds
            try click(c, CGPoint(x: bounds.midX, y: bounds.midY))
            #expect(c.selectedItem == 0)
            #expect(try #require(c.renderPNG()) == before)
            try dragFrom(c, CGPoint(x: bounds.midX, y: bounds.midY), to: CGPoint(x: bounds.midX + 40, y: bounds.midY + 30))
            let moved = c.document.items[0].bounds
            #expect(abs(moved.minX - (bounds.minX + 40)) < 1e-6 && abs(moved.minY - (bounds.minY + 30)) < 1e-6)
            c.clearCanvas()
            #expect(c.document.items.isEmpty && c.selectedItem == nil)
        }
    }

    @Test("縁の外にある取っ手は、触っただけでは跳ねず、取り消しの段も作らない（直線の端）")
    func handleOutsideTheCanvasDoesNotJump() throws {
        let c = canvas([lineItem(CGPoint(x: 300, y: 100), CGPoint(x: 485, y: 100))])
        try click(c, CGPoint(x: 400, y: 100))
        try dragFrom(c, CGPoint(x: 480, y: 100), to: CGPoint(x: 480, y: 100))
        #expect(shape(c) == .line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 485, y: 100)))
        c.undo()
        #expect(c.document.items.isEmpty)
    }

    @Test("ごく小さい枠（短い辺が 4 pt 未満）は、大きさの取っ手が無い。選ばれていても、ドラッグは、動かす")
    func tinyBoxesAreMovable() throws {
        let c = canvas([rectItem(CGRect(x: 100, y: 100, width: 2, height: 2))])
        try click(c, CGPoint(x: 101, y: 101))
        try dragFrom(c, CGPoint(x: 101, y: 101), to: CGPoint(x: 151, y: 131))
        #expect(box(c) == CGRect(x: 150, y: 130, width: 2, height: 2))
    }

    @Test("取り消し・クリアで、選びが外れる")
    func selectionClears() throws {
        let c = canvas([rectItem(rect)])
        try click(c, CGPoint(x: 200, y: 150))
        c.undo(); #expect(c.selectedItem == nil)
        c.redo(); try click(c, CGPoint(x: 200, y: 150))
        #expect(c.clearFromAgent()); #expect(c.selectedItem == nil)
    }
}

@Suite("操作の JSON：rotate（A30）")
struct RotateOpsTests {
    private func parse(_ ops: String) -> Result<[Op], AgentError> { OpsParser.parse(Data("{\"version\":1,\"ops\":[\(ops)]}".utf8)) }

    @Test("ellipse・rect・text・image に rotate（度）。省くと 0。数値だけ（文字列・真偽値・null は、エラー）。pen・line には無い")
    func parsesRotate() throws {
        let ops = try parse(#"{"op":"rect","x":1,"y":2,"w":30,"h":20,"rotate":45},{"op":"ellipse","x":1,"y":2,"w":30,"h":20},{"op":"text","x":1,"y":2,"text":"a","rotate":-90.5},{"op":"image","path":"/x.png","x":1,"y":2,"rotate":720}"#).get()
        #expect(ops[0] == .rect(rect: CGRect(x: 1, y: 2, width: 30, height: 20), color: .black, size: 4, fill: false, rotate: 45))
        #expect(ops[1] == .ellipse(rect: CGRect(x: 1, y: 2, width: 30, height: 20), color: .black, size: 4, fill: false, rotate: 0))
        #expect(ops[2] == .text("a", at: CGPoint(x: 1, y: 2), color: .black, fontSize: 18, rotate: -90.5))
        #expect(ops[3] == .image(path: "/x.png", at: CGPoint(x: 1, y: 2), width: nil, height: nil, rotate: 720))
        for bad in ["\"45\"", "true", "null", "[1]"] {
            if case .success = parse(#"{"op":"rect","x":1,"y":2,"w":30,"h":20,"rotate":\#(bad)}"#) { Issue.record("rotate \(bad) が通った") }
        }
        if case .success = parse(#"{"op":"line","from":[0,0],"to":[5,5],"rotate":10}"#) { Issue.record("line に rotate が通った") }
        if case .success = parse(#"{"op":"pen","points":[[0,0]],"rotate":10}"#) { Issue.record("pen に rotate が通った") }
    }

    @Test("適用すると、要素の回転角（ラジアン。(-π, π]）になり、get の rotate（度）で読み直すと、同じ値に戻る")
    func appliesAndRoundTrips() throws {
        let ops = try OpsParser.parse(Data(#"{"version":1,"ops":[{"op":"rect","x":10,"y":10,"w":50,"h":20,"rotate":450},{"op":"text","x":5,"y":5,"text":"hi","rotate":-30}]}"#.utf8)).get()
        let result = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get()
        #expect(abs(result.items[0].rotation - .pi / 2) < 1e-9)
        #expect(abs(result.items[1].rotation + .pi / 6) < 1e-9)
        let json = ItemEncoder.json(result.items[0], index: 0)
        #expect((json["rotate"] as? NSDecimalNumber)?.doubleValue == 90)
        // get の出力を、そのまま draw の操作として読める
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "ops": [json.filter { $0.key != "index" }]])
        let again = try OpsParser.parse(data).get()
        let items = try OpsApply.items(from: again, canvas: CGSize(width: 480, height: 320)).get().items
        #expect(abs(items[0].rotation - .pi / 2) < 1e-6)
    }
}

@Suite("回転の安全（レビューの指摘）")
struct RotationSafetyTests {
    @Test("rotate に、とても大きい有限の値でも、回転角は NaN にならず、掴める")
    func hugeRotateStaysFinite() throws {
        for degrees in ["1e308", "-1.7e308", "1e300", "5e306"] {
            let ops = try OpsParser.parse(Data(#"{"version":1,"ops":[{"op":"rect","x":10,"y":10,"w":50,"h":20,"rotate":\#(degrees)}]}"#.utf8)).get()
            let item = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get().items[0]
            #expect(item.rotation.isFinite && item.rotation > -.pi - 1e-9 && item.rotation <= .pi, "rotate \(degrees) → \(item.rotation)")
            #expect(item.bounds.minX.isFinite)
            #expect(Document().appending(item).topItemIndex(at: CGPoint(x: 35, y: 20)) == 0, "rotate \(degrees)")
        }
    }

    @Test("回したあとの掴める範囲が、キャンバスの中に残らなくなる向きは、keepsGrabArea が断る。いまの向きと、残る向きは、通す")
    func keepsGrabAreaAfterRotation() throws {
        // 10×300 の縦長の四角を、上へ寄せて、16 pt だけキャンバスに残した状態（掴める範囲は、4 pt 広い）
        let base = Document().appending(Item(content: .rect(CGRect(x: 200, y: -280, width: 10, height: 300)), color: black, size: 4))
        #expect(base.keepsGrabArea(at: 0, since: base, in: canvasRect))
        let far = try #require(base.rotating(itemAt: 0, by: -.pi / 3))                 // 縁の外へ出て行く向き
        #expect(!far.keepsGrabArea(at: 0, since: base, in: canvasRect))
        let straightDown = try #require(base.rotating(itemAt: 0, by: .pi))             // 中心が同じで、上下が入れ替わるだけ
        #expect(straightDown.keepsGrabArea(at: 0, since: base, in: canvasRect))
        #expect(base.keepsGrabArea(at: 9, since: base, in: canvasRect))                // 範囲外の番号は、断らない
    }

    @Test("キャンバスの操作：回して、要素がキャンバスの外へ出てしまう向きには、回らない（掴めなくならない）")
    func rotateCannotCarryAnItemOutOfReach() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.appendFromAgent([Item(content: .rect(CGRect(x: 200, y: -280, width: 10, height: 300)), color: black, size: 4)])
        canvas.tool = .move
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let before = canvas.document.items[0]
        let areaCenter = CGPoint(x: 205, y: 10)
        canvas.mouseDown(with: try mouse(.leftMouseDown, areaCenter)); canvas.mouseUp(with: try mouse(.leftMouseUp, areaCenter))    // 選ぶ
        let target = try #require(canvas.document.resizeTarget(at: 0))
        let knob = ItemHandles.rotationHandle(of: target.shape, canvas: CGRect(x: 0, y: 0, width: 480, height: 320)).handle
        canvas.mouseDown(with: try mouse(.leftMouseDown, knob))
        for p in [CGPoint(x: 480, y: 0), CGPoint(x: 400, y: 5), CGPoint(x: 300, y: 0)] { canvas.mouseDragged(with: try mouse(.leftMouseDragged, p)) }
        canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 300, y: 0)))
        let after = canvas.document.items[0]
        let area = after.bounds.insetBy(dx: -4, dy: -4)
        #expect(area.intersection(CGRect(x: 0, y: 0, width: 480, height: 320)).height >= 16 || area.intersection(CGRect(x: 0, y: 0, width: 480, height: 320)).isNull == false,
                "bounds=\(after.bounds) rotation=\(after.rotation) before=\(before.rotation)")
        #expect(canvas.document.topItemIndex(at: CGPoint(x: after.bounds.midX, y: max(1, min(after.bounds.maxY - 1, 319)))) != nil || after.rotation == before.rotation)
    }
}
