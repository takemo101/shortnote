import CoreGraphics
import Testing
@testable import ShortNoteKit

/// 手で描いたようなゆらぎ（決まった乱数。結果が毎回同じ）。
private struct Wobble {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ amount: CGFloat) -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (CGFloat(state >> 33) / CGFloat(1 << 31) - 0.5) * 2 * amount
    }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// 折れ線を、`perEdge` 個ずつに分けて、ゆらぎをつけた点の並び（閉じた図形は、始点に戻る手前で、少し足りない）。
private func stroke(through corners: [CGPoint], perEdge: Int = 24, wobble: CGFloat = 1.2, seed: UInt64 = 7, overshoot: CGFloat = 0) -> [CGPoint] {
    var w = Wobble(seed: seed)
    var out: [CGPoint] = []
    for i in 0..<(corners.count - 1) {
        let a = corners[i], b = corners[i + 1]
        for k in 0..<perEdge {
            let t = CGFloat(k) / CGFloat(perEdge)
            out.append(pt(a.x + (b.x - a.x) * t + w.next(wobble), a.y + (b.y - a.y) * t + w.next(wobble)))
        }
    }
    out.append(corners[corners.count - 1])
    return out
}

private func ellipseStroke(center: CGPoint, a: CGFloat, b: CGFloat, rotation: CGFloat = 0, wobble: CGFloat = 1.5, turns: CGFloat = 1.04, seed: UInt64 = 3) -> [CGPoint] {
    var w = Wobble(seed: seed)
    let n = 80
    return (0...n).map { i in
        let t = CGFloat(i) / CGFloat(n) * 2 * .pi * turns
        let r = 1 + 0.03 * sin(3 * t)
        let x = a * r * cos(t), y = b * r * sin(t)
        return pt(center.x + x * cos(rotation) - y * sin(rotation) + w.next(wobble), center.y + x * sin(rotation) + y * cos(rotation) + w.next(wobble))
    }
}

@Suite("手書きの形の整形：認識（A37）")
struct ShapeRecognizerTests {
    @Test("円：ゆらぎのある円が、楕円になる。外接する枠が、描いた円に合い、傾きは、水平に直る")
    func circle() throws {
        let shape = try #require(ShapeRecognizer.recognize(ellipseStroke(center: pt(200, 150), a: 60, b: 60)))
        guard case .ellipse(let rect, let rotation) = shape else { Issue.record("楕円でない：\(shape)"); return }
        #expect(abs(rect.midX - 200) < 5 && abs(rect.midY - 150) < 5 && abs(rect.width - 120) < 12 && abs(rect.height - 120) < 12)
        #expect(rotation == 0 || abs(rotation) < 0.8)
    }

    @Test("傾いた楕円：傾きを保って置く（30°）")
    func rotatedEllipse() throws {
        let shape = try #require(ShapeRecognizer.recognize(ellipseStroke(center: pt(250, 200), a: 90, b: 40, rotation: 30 * .pi / 180)))
        guard case .ellipse(let rect, let rotation) = shape else { Issue.record("楕円でない：\(shape)"); return }
        #expect(abs(rotation - 30 * .pi / 180) < 5 * .pi / 180, "rotation=\(rotation * 180 / .pi)°")
        #expect(abs(rect.width - 180) < 20 && abs(rect.height - 80) < 16)
    }

    @Test("四角：4 つの辺を、ゆらぎつきで描くと、四角になる。始点まで戻りきらなくても、よい。水平・垂直に直る")
    func rectangle() throws {
        let corners = [pt(100, 100), pt(260, 100), pt(260, 200), pt(100, 200), pt(100, 112)]
        let shape = try #require(ShapeRecognizer.recognize(stroke(through: corners)))
        guard case .rect(let rect, let rotation) = shape else { Issue.record("四角でない：\(shape)"); return }
        #expect(rotation == 0)
        #expect(abs(rect.minX - 100) < 6 && abs(rect.maxX - 260) < 6 && abs(rect.minY - 100) < 6 && abs(rect.maxY - 200) < 6)
    }

    @Test("傾いた四角（20°）：傾きを保つ")
    func rotatedRectangle() throws {
        let center = pt(220, 180)
        let corners = [pt(-80, -45), pt(80, -45), pt(80, 45), pt(-80, 45), pt(-80, -33)].map { p -> CGPoint in
            let a = 20 * CGFloat.pi / 180
            return pt(center.x + p.x * cos(a) - p.y * sin(a), center.y + p.x * sin(a) + p.y * cos(a))
        }
        let shape = try #require(ShapeRecognizer.recognize(stroke(through: corners)))
        guard case .rect(let rect, let rotation) = shape else { Issue.record("四角でない：\(shape)"); return }
        #expect(abs(rotation - 20 * .pi / 180) < 4 * .pi / 180, "rotation=\(rotation * 180 / .pi)°")
        #expect(abs(rect.width - 160) < 16 && abs(rect.height - 90) < 14)
    }

    @Test("三角：頂点が上の三角が、このアプリの三角形（二等辺三角形）になる。底辺が下辺、頂点が上辺の中央")
    func triangleApexUp() throws {
        let corners = [pt(200, 80), pt(290, 220), pt(110, 220), pt(196, 90)]
        let shape = try #require(ShapeRecognizer.recognize(stroke(through: corners, perEdge: 28)))
        guard case .triangle(let rect, let rotation) = shape else { Issue.record("三角形でない：\(shape)"); return }
        #expect(rotation == 0)
        #expect(abs(rect.minX - 110) < 10 && abs(rect.maxX - 290) < 10 && abs(rect.minY - 80) < 8 && abs(rect.maxY - 220) < 8)
    }

    @Test("三角：頂点が右を向く三角は、90°回った三角形になる")
    func triangleApexRight() throws {
        // 頂点 (300,200)、底辺 x=160 の縦の辺（上 (160,110)、下 (160,290)）
        let corners = [pt(300, 200), pt(160, 290), pt(160, 110), pt(290, 196)]
        let shape = try #require(ShapeRecognizer.recognize(stroke(through: corners, perEdge: 28)))
        guard case .triangle(_, let rotation) = shape else { Issue.record("三角形でない：\(shape)"); return }
        #expect(abs(abs(rotation) - .pi / 2) < 0.15, "rotation=\(rotation * 180 / .pi)°")
        let polygon: [CGPoint]
        if case .triangle(let rect, let angle) = shape {
            polygon = Triangle.points(in: rect).map { ItemHandles.rotate($0, about: CGPoint(x: rect.midX, y: rect.midY), by: angle) }
        } else { polygon = [] }
        // 頂点（回した結果）は、右端（300,200）の近く
        let apex = polygon.max { $0.x < $1.x }!
        #expect(abs(apex.x - 300) < 12 && abs(apex.y - 200) < 12)
    }

    @Test("直線：まっすぐな線が、直線になる（始点から終点へ）。短い線・曲がった線は、ならない")
    func line() throws {
        let shape = try #require(ShapeRecognizer.recognize(stroke(through: [pt(50, 60), pt(310, 140)], perEdge: 40)))
        guard case .line(let from, let to) = shape else { Issue.record("直線でない：\(shape)"); return }
        #expect(hypot(from.x - 50, from.y - 60) < 4 && hypot(to.x - 310, to.y - 140) < 4)
        #expect(ShapeRecognizer.recognize(stroke(through: [pt(50, 60), pt(70, 70)], perEdge: 10)) == nil)              // 短い
        let arc = (0...40).map { i -> CGPoint in let t = CGFloat(i) / 40 * .pi; return pt(100 + 100 * cos(t), 200 - 100 * sin(t)) }
        #expect(ShapeRecognizer.recognize(arc) == nil)                                                                   // 半円
    }

    @Test("矢印：まっすぐな軸の先で、軸の後ろへ折り返す短い線（矢じり）が付いた 1 画は、矢印になる（終点は、折り返す所）")
    func arrow() throws {
        let corners = [pt(50, 200), pt(300, 200), pt(272, 183), pt(300, 200), pt(272, 217)]
        let shape = try #require(ShapeRecognizer.recognize(stroke(through: corners, perEdge: 30, wobble: 0.8)))
        guard case .arrow(let from, let to) = shape else { Issue.record("矢印でない：\(shape)"); return }
        #expect(hypot(from.x - 50, from.y - 200) < 5 && hypot(to.x - 300, to.y - 200) < 8)
        // 軸だけ・矢じりの片方だけでも
        let single = [pt(60, 100), pt(260, 180), pt(232, 178)]
        if case .arrow? = ShapeRecognizer.recognize(stroke(through: single, perEdge: 30, wobble: 0.5)) {} else { Issue.record("片方だけの矢じりが、矢印にならない") }
    }

    @Test("図形にならないもの：ジグザグ・渦巻・小さな丸・行って戻っただけの線・点が少ない線")
    func notRecognized() {
        let zigzag = stroke(through: [pt(50, 50), pt(90, 150), pt(130, 50), pt(170, 150), pt(210, 50), pt(250, 150)], perEdge: 16)
        #expect(ShapeRecognizer.recognize(zigzag) == nil)
        let spiral = (0...120).map { i -> CGPoint in let t = CGFloat(i) / 120 * 6 * .pi; let r = 10 + 8 * t; return pt(200 + r * cos(t), 200 + r * sin(t)) }
        #expect(ShapeRecognizer.recognize(spiral) == nil)
        #expect(ShapeRecognizer.recognize(ellipseStroke(center: pt(100, 100), a: 4, b: 4, wobble: 0.3)) == nil)         // 小さい（周りが 30 pt 未満）
        let backAndForth = stroke(through: [pt(50, 100), pt(250, 104), pt(52, 106)], perEdge: 30, wobble: 0.8)
        #expect(ShapeRecognizer.recognize(backAndForth) == nil)
        #expect(ShapeRecognizer.recognize([pt(0, 0), pt(40, 0), pt(80, 0)]) == nil)                                      // 点が少ない
        #expect(ShapeRecognizer.recognize([]) == nil)
        #expect(ShapeRecognizer.recognize([pt(0, 0), pt(.nan, 5), pt(10, 10), pt(20, 20), pt(30, 30)]) == nil)
    }
}

@Suite("手書きの形の整形：ゆらぎへの強さ（A37）")
struct ShapeRecognizerRobustnessTests {
    private func kind(_ shape: RecognizedShape?) -> String {
        switch shape {
        case .line?: return "line"
        case .arrow?: return "arrow"
        case .ellipse?: return "ellipse"
        case .rect?: return "rect"
        case .triangle?: return "triangle"
        case nil: return "none"
        }
    }

    @Test("大きめのゆらぎ（3 pt）・20 通りの乱数でも、円・四角・三角・直線・矢印が、取り違えられずに見分けられる")
    func manySeeds() {
        var wrong: [String] = []
        for seed in UInt64(1)...20 {
            let cases: [(String, [CGPoint])] = [
                ("ellipse", ellipseStroke(center: pt(220, 180), a: 70, b: 62, wobble: 3, turns: 1.06, seed: seed)),
                ("rect", stroke(through: [pt(100, 100), pt(280, 104), pt(276, 210), pt(98, 206), pt(102, 118)], perEdge: 26, wobble: 2.5, seed: seed)),
                ("triangle", stroke(through: [pt(200, 90), pt(300, 230), pt(100, 226), pt(204, 104)], perEdge: 28, wobble: 2.5, seed: seed)),
                ("line", stroke(through: [pt(60, 80), pt(320, 170)], perEdge: 50, wobble: 2.5, seed: seed)),
                ("arrow", stroke(through: [pt(50, 200), pt(300, 196), pt(270, 180), pt(300, 196), pt(272, 214)], perEdge: 30, wobble: 1.5, seed: seed)),
            ]
            for (expected, points) in cases where kind(ShapeRecognizer.recognize(points)) != expected {
                wrong.append("\(expected)#\(seed)→\(kind(ShapeRecognizer.recognize(points)))")
            }
        }
        #expect(wrong.isEmpty, "取り違え・見逃し：\(wrong)")
    }
}

@Suite("手書きの形の整形：レビューの指摘（A37）")
struct ShapeRecognizerReviewTests {
    private func kind(_ shape: RecognizedShape?) -> String {
        switch shape {
        case .line?: return "line"
        case .arrow?: return "arrow"
        case .ellipse?: return "ellipse"
        case .rect?: return "rect"
        case .triangle?: return "triangle"
        case nil: return "none"
        }
    }

    /// 閉じた折れ線の、辺の途中（`offset`：全体の長さに対する割合）から描き始めて、一周する点の並び。
    private func ring(_ corners: [CGPoint], startingAt offset: CGFloat, wobble: CGFloat, seed: UInt64) -> [CGPoint] {
        let closed = corners + [corners[0]]
        let lengths = (1..<closed.count).map { hypot(closed[$0].x - closed[$0 - 1].x, closed[$0].y - closed[$0 - 1].y) }
        let total = lengths.reduce(0, +)
        var w = Wobble(seed: seed)
        var out: [CGPoint] = []
        let n = 120
        for i in 0...n {
            var d = (offset + CGFloat(i) / CGFloat(n) * 0.97).truncatingRemainder(dividingBy: 1) * total
            var edge = 0
            while edge < lengths.count - 1, d > lengths[edge] { d -= lengths[edge]; edge += 1 }
            let t = d / lengths[edge]
            let a = closed[edge], b = closed[edge + 1]
            out.append(pt(a.x + (b.x - a.x) * t + w.next(wobble), a.y + (b.y - a.y) * t + w.next(wobble)))
        }
        return out
    }

    @Test("三角：辺の途中から描き始めても、三角になる（どこから始めても）")
    func triangleFromAnywhere() {
        let corners = [pt(200, 80), pt(300, 230), pt(100, 226)]
        var wrong: [String] = []
        for start in stride(from: CGFloat(0), to: 1, by: 0.1) {
            for seed in UInt64(1)...6 {
                let result = kind(ShapeRecognizer.recognize(ring(corners, startingAt: start, wobble: 2, seed: seed)))
                if result != "triangle" { wrong.append("start=\(start) seed=\(seed)→\(result)") }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(8))（\(wrong.count) 件）")
    }

    @Test("矢印：先端に戻って、2 本目の矢じりを描く 1 画も、矢印になる（矢じりの張り出しが、軸の 15〜20%・35〜40° でも）")
    func arrowWithWideHeads() {
        var wrong: [String] = []
        for (headLength, degrees) in [(0.15, 40.0), (0.20, 35.0), (0.12, 45.0)] {
            for seed in UInt64(1)...10 {
                let shaft: CGFloat = 250, h = CGFloat(headLength) * shaft, a = CGFloat(degrees) * .pi / 180
                let tip = pt(300, 200)
                let arm1 = pt(tip.x - h * cos(a), tip.y - h * sin(a)), arm2 = pt(tip.x - h * cos(a), tip.y + h * sin(a))
                let result = kind(ShapeRecognizer.recognize(stroke(through: [pt(50, 200), tip, arm1, tip, arm2], perEdge: 30, wobble: 1.5, seed: seed)))
                if result != "arrow" { wrong.append("\(headLength)/\(degrees)°#\(seed)→\(result)") }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(8))（\(wrong.count) 件）")
    }

    @Test("水平・垂直に近い四角は、6° 以内なら、水平に直す（5° でも、直る）。直したあとの枠は、水平の枠で計る")
    func snapsNearlyLevelRectangles() throws {
        for degrees in [-5.5, -3.0, 2.0, 5.0] as [CGFloat] {
            let a = degrees * .pi / 180, center = pt(200, 150)
            let corners = [pt(-100, -50), pt(100, -50), pt(100, 50), pt(-100, 50), pt(-100, -38)].map { p in
                pt(center.x + p.x * cos(a) - p.y * sin(a), center.y + p.x * sin(a) + p.y * cos(a))
            }
            let shape = try #require(ShapeRecognizer.recognize(stroke(through: corners, perEdge: 26, wobble: 0.3)))
            guard case .rect(_, let rotation) = shape else { Issue.record("四角でない：\(shape)（\(degrees)°）"); continue }
            #expect(rotation == 0, "\(degrees)° の四角が、\(rotation * 180 / .pi)° のまま")
        }
        // 10° は、直さない
        let a = 10 * CGFloat.pi / 180
        let tilted = [pt(-100, -50), pt(100, -50), pt(100, 50), pt(-100, 50), pt(-100, -38)].map { pt(200 + $0.x * cos(a) - $0.y * sin(a), 150 + $0.x * sin(a) + $0.y * cos(a)) }
        guard case .rect(_, let rotation)? = ShapeRecognizer.recognize(stroke(through: tilted, perEdge: 26, wobble: 0.3)) else { Issue.record("四角でない"); return }
        #expect(abs(rotation - a) < 3 * .pi / 180)
    }

    @Test("ほぼ円は、傾けない（回転 0）。細長い楕円の傾きは、保つ")
    func nearlyRoundEllipsesStayLevel() throws {
        for seed in UInt64(1)...10 {
            guard case .ellipse(_, let rotation)? = ShapeRecognizer.recognize(ellipseStroke(center: pt(200, 150), a: 70, b: 64, wobble: 2.5, seed: seed)) else { Issue.record("楕円でない#\(seed)"); continue }
            #expect(rotation == 0, "seed=\(seed) rotation=\(rotation * 180 / .pi)°")
        }
    }

    @Test("正三角形に近い三角：頂点が上なら、傾き 0（±120° にならない）")
    func equilateralTriangleStaysLevel() throws {
        let corners = [pt(200, 70), pt(300, 243), pt(100, 243)]
        for seed in UInt64(1)...10 {
            guard case .triangle(_, let rotation)? = ShapeRecognizer.recognize(stroke(through: corners + [pt(204, 80)], perEdge: 28, wobble: 2, seed: seed)) else { Issue.record("三角形でない#\(seed)"); continue }
            #expect(abs(rotation) < 0.05, "seed=\(seed) rotation=\(rotation * 180 / .pi)°")
        }
    }

    @Test("四角にならないもの：平行四辺形（大きなずれ）。300° の弧（C の字）")
    func notARectangleNotAnArc() {
        let parallelogram = [pt(150, 100), pt(330, 100), pt(250, 200), pt(70, 200), pt(140, 112)]
        #expect(kind(ShapeRecognizer.recognize(stroke(through: parallelogram, perEdge: 26, wobble: 0.5))) != "rect")
        let arc = (0...60).map { i -> CGPoint in let t = CGFloat(i) / 60 * 300 * .pi / 180; return pt(200 + 70 * cos(t), 150 + 70 * sin(t)) }
        #expect(ShapeRecognizer.recognize(arc) == nil)
    }
}
