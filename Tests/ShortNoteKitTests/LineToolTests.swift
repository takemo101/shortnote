import AppKit
import Testing
@testable import ShortNoteKit

@Suite("直線ツール")
struct LineToolTests {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let canvas = CGRect(x: 0, y: 0, width: 480, height: 320)

    private func line(_ a: CGPoint, _ b: CGPoint, size: CGFloat = 4) -> Item {
        Item(content: .line(from: a, to: b), color: red, size: size)
    }

    @Test("直線は、始点から終点までに引かれ、それ以外の所には引かれない（書き出し PNG の画素）")
    func rendersFromStartToEndOnly() throws {
        let doc = Document().appending(line(CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 120), size: 6))
        let data = try #require(CanvasRenderer.pngData(doc, size: CGSize(width: 480, height: 320), transparent: false))
        let rep = try #require(NSBitmapImageRep(data: data))
        func color(_ x: Double, _ y: Double) -> NSColor { rep.colorAt(x: Int(x * 2), y: Int(y * 2))!.usingColorSpace(.deviceRGB)! }
        let mid = color(120, 80), start = color(40, 40), end = color(200, 120)
        for c in [mid, start, end] { #expect(c.redComponent > 0.9 && c.greenComponent < 0.4 && c.blueComponent < 0.2, "got \(c)") }   // sRGB の赤を deviceRGB で読むと g が 0.25 ほどになる
        // 線の外（同じ x で、線の上と下）と、終点の先は、白のまま
        for c in [color(120, 40), color(120, 130), color(260, 150)] { #expect(c.greenComponent > 0.9 && c.blueComponent > 0.9) }
    }

    @Test("直線の範囲は、始点と終点の外接する範囲に、線の太さの半分を足したもの。向きによらない")
    func boundsDoNotDependOnTheDirection() {
        let a = line(CGPoint(x: 110, y: 60), CGPoint(x: 10, y: 10), size: 4)   // 右下から左上へ
        let b = line(CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60), size: 4)
        #expect(a.bounds == CGRect(x: 8, y: 8, width: 104, height: 54))
        #expect(b.bounds == a.bounds)
    }

    @Test("直線を動かすと、始点と終点が、同じだけ動く")
    func translatingMovesBothEnds() throws {
        let moved = line(CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)).translated(by: CGSize(width: 30, height: -5))
        guard case .line(let from, let to) = moved.content else { Issue.record("直線でなくなった"); return }
        #expect(from == CGPoint(x: 40, y: 5))
        #expect(to == CGPoint(x: 140, y: 55))
    }

    @Test("直線は、他の図形と同じく、外接する範囲の中で掴める（線から離れた範囲の中の空白も）。範囲の外は掴めない")
    func grabbedInsideTheBoundingBox() {
        let doc = Document().appending(line(CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)))
        #expect(doc.topItemIndex(at: CGPoint(x: 60, y: 35)) == 0)      // 線の上
        #expect(doc.topItemIndex(at: CGPoint(x: 100, y: 15)) == 0)     // 線から離れた、範囲の隅
        #expect(doc.topItemIndex(at: CGPoint(x: 300, y: 200)) == nil)
    }

    @Test("直線を、キャンバスの外へ遠く動かしても、掴める範囲が残り、また掴める（斜めの線の、線のない隅を掴んだ場合も）")
    func canStillBeGrabbedAfterAHugeMove() {
        let doc = Document().appending(line(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200)))   // 左上から右下への線。右上の隅には、線がない
        let far = doc.translatingItem(at: 0, by: CGSize(width: 99999, height: -99999), keepingGrabAreaIn: canvas)
        let grabbable = (0..<480).contains { x in (0..<320).contains { y in far?.topItemIndex(at: CGPoint(x: x, y: y)) == 0 } }
        #expect(grabbable)
    }

    @Test("ツールのキーは、直線が 6、三角が 7。1〜5 は、これまでどおり")
    func defaultKeys() {
        let b = KeyBindings()
        func command(_ code: UInt16, _ label: String) -> Command? { b.command(for: KeyChord(keyCode: code, label: label), whileEditingText: false) }
        #expect(command(18, "1") == .toolPen)
        #expect(command(19, "2") == .toolEllipse)
        #expect(command(20, "3") == .toolRect)
        #expect(command(21, "4") == .toolText)
        #expect(command(23, "5") == .toolMove)
        #expect(command(22, "6") == .toolLine)
        #expect(command(26, "7") == .toolTriangle)
        #expect(Command.toolLine.group == .tool && Command.toolTriangle.group == .tool)
    }

    @Test("ツールバーの並びは、ペン／直線／図形（円・四角・三角）／文字／消しゴム／移動／ハンド。直線はペンの隣（2 番目）")
    func toolSegmentOrder() {
        #expect(Tool.allCases == [.pen, .line, .ellipse, .rect, .triangle, .text, .move, .hand, .eraser])
        #expect([Tool.pen, .line, .ellipse, .rect, .triangle, .text, .eraser, .move, .hand].map(Toolbar.segment(for:)) == [0, 1, 2, 2, 2, 3, 4, 5, 6])
    }
}
