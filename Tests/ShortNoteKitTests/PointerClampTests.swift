import CoreGraphics
import Testing
@testable import ShortNoteKit

@Suite("ポインタの丸め")
struct PointerClampTests {
    private let canvas = CGRect(x: 0, y: 0, width: 480, height: 320)

    @Test("範囲の中の点は、そのまま")
    func insideIsUnchanged() {
        #expect(CGPoint(x: 120.5, y: 99).clamped(to: canvas) == CGPoint(x: 120.5, y: 99))
        #expect(CGPoint(x: 0, y: 320).clamped(to: canvas) == CGPoint(x: 0, y: 320))   // 縁は範囲の中
    }

    @Test("外へ出た点は、出た軸だけ、縁の位置になる")
    func outsideGoesToTheEdgeOnTheAxisThatLeft() {
        #expect(CGPoint(x: 488, y: 50).clamped(to: canvas) == CGPoint(x: 480, y: 50))     // 右の外
        #expect(CGPoint(x: 100, y: -30).clamped(to: canvas) == CGPoint(x: 100, y: 0))     // 上の外
        #expect(CGPoint(x: -5, y: 400).clamped(to: canvas) == CGPoint(x: 0, y: 320))      // 左下の外（両方の軸）
    }

    @Test("原点がずれた範囲でも、範囲の中に収まる")
    func offsetRect() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(CGPoint(x: 0, y: 0).clamped(to: r) == CGPoint(x: 10, y: 20))
        #expect(CGPoint(x: 500, y: 500).clamped(to: r) == CGPoint(x: 110, y: 70))
    }
}
