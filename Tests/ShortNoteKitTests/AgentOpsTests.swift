import CoreGraphics
import Foundation
import Testing
@testable import ShortNoteKit

private func parse(_ json: String) -> Result<[Op], AgentError> { OpsParser.parse(Data(json.utf8)) }
private func wrap(_ ops: String) -> String { "{\"version\":1,\"ops\":[\(ops)]}" }

@Suite("操作の JSON の検証")
struct OpsParserTests {
    @Test("6 つの操作が読め、既定値が入る")
    func parsesEveryOpWithDefaults() throws {
        let ops = try parse(wrap("""
        {"op":"pen","points":[[1,2],[3,4]]},
        {"op":"line","from":[0,0],"to":[10,0]},
        {"op":"ellipse","x":1,"y":2,"w":30,"h":40,"color":"#FF000080","size":10},
        {"op":"rect","x":5,"y":6,"w":7,"h":8},
        {"op":"text","x":9,"y":10,"text":"hi"},
        {"op":"image","path":"/tmp/a.png","x":1,"y":2,"w":50}
        """)).get()
        #expect(ops.count == 6)
        #expect(ops[0] == .pen(points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], color: .black, size: 4))
        #expect(ops[2] == .ellipse(rect: CGRect(x: 1, y: 2, width: 30, height: 40), color: RGBA(hex: "#FF000080")!, size: 10))
        #expect(ops[4] == .text("hi", at: CGPoint(x: 9, y: 10), color: .black, fontSize: 18))
        #expect(ops[5] == .image(path: "/tmp/a.png", at: CGPoint(x: 1, y: 2), width: 50, height: nil))
    }

    @Test("色：#RRGGBB と #RRGGBBAA。アルファは 255 分の値")
    func hexColors() {
        #expect(RGBA(hex: "#000000") == .black)
        #expect(RGBA(hex: "#ff8000")?.g == 128.0 / 255)
        #expect(RGBA(hex: "#00000080")?.a == 128.0 / 255)
        for bad in ["red", "#12345", "#1234567", "000000", "#GG0000", "#"] { #expect(RGBA(hex: bad) == nil, "\(bad)") }
    }

    @Test("範囲の外の座標は、エラーにしない（丸めるのは、適用のとき）")
    func outOfRangeCoordinatesAreAccepted() throws {
        let ops = try parse(wrap("""
        {"op":"line","from":[-500,-500],"to":[99999,99999]},
        {"op":"rect","x":-10,"y":-10,"w":100000,"h":5}
        """)).get()
        #expect(ops.count == 2)
    }

    @Test("不正な JSON は、何番目の操作かを示して断る", arguments: [
        (#"{"version":1,"ops":[{"op":"cube"}]}"#, 0),                                              // 知らない op
        (#"{"version":1,"ops":[{"op":"pen","points":[[1,1]]},{"op":"rect","x":1,"y":1,"w":0,"h":5}]}"#, 1),   // 2 番目が不正（1 番目は正しい）
        (##"{"version":1,"ops":[{"op":"rect","x":1,"y":1,"w":5,"h":5,"colour":"#000000"}]}"##, 0),   // 知らない項目
        (#"{"version":1,"ops":[{"op":"rect","x":"1","y":1,"w":5,"h":5}]}"#, 0),                    // 型の違い
        (#"{"version":1,"ops":[{"op":"rect","x":true,"y":1,"w":5,"h":5}]}"#, 0),                   // 真偽値は数値ではない
        (#"{"version":1,"ops":[{"op":"line","from":[0,0],"to":[0.5,0]}]}"#, 0),                    // 1 pt 未満の直線
        (#"{"version":1,"ops":[{"op":"ellipse","x":0,"y":0,"w":5,"h":0.5}]}"#, 0),                 // 大きさのない図形
        (#"{"version":1,"ops":[{"op":"pen","points":[]}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"pen","points":[[1,2,3]]}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"line","from":[0,0],"to":[5,5],"size":0}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"line","from":[0,0],"to":[5,5],"size":41}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"text","x":0,"y":0,"text":"a","fontSize":7}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"text","x":0,"y":0,"text":"a","fontSize":201}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"text","x":0,"y":0,"text":"  \n "}]}"#, 0),                   // 空白だけ
        (#"{"version":1,"ops":[{"op":"rect","x":0,"y":0,"w":5,"h":5,"color":"red"}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"image","path":"","x":0,"y":0}]}"#, 0),
        (#"{"version":1,"ops":[{"op":"image","path":"/a.png","x":0,"y":0,"w":0}]}"#, 0),
    ])
    func rejectsInvalidOps(json: String, index: Int) {
        guard case .failure(let error) = parse(json) else { Issue.record("通ってしまった：\(json)"); return }
        #expect(error.code == .invalidOps)
        #expect(error.exitCode == 1)
        #expect(error.op == index)
    }

    @Test("全体の形の誤りと、上限")
    func rejectsInvalidDocuments() {
        let tooMany = wrap(Array(repeating: #"{"op":"pen","points":[[1,1]]}"#, count: 1001).joined(separator: ","))
        let manyImages = wrap(Array(repeating: #"{"op":"image","path":"/a.png","x":0,"y":0}"#, count: 21).joined(separator: ","))
        let longText = wrap(#"{"op":"text","x":0,"y":0,"text":""# + String(repeating: "あ", count: 10_001) + #""}"#)
        for (name, json) in [
            ("JSON ではない", "not json"),
            ("配列", "[]"),
            ("version 2", #"{"version":2,"ops":[{"op":"pen","points":[[1,1]]}]}"#),
            ("version なし", #"{"ops":[{"op":"pen","points":[[1,1]]}]}"#),
            ("知らない最上位の項目", #"{"version":1,"ops":[{"op":"pen","points":[[1,1]]}],"extra":1}"#),
            ("ops が空", #"{"version":1,"ops":[]}"#),
            ("ops が 1001 個", tooMany),
            ("画像が 21 枚", manyImages),
            ("文字が 10001", longText),
        ] {
            guard case .failure(let error) = parse(json) else { Issue.record("通ってしまった：\(name)"); continue }
            #expect(error.code == .invalidOps, "\(name)")
        }
    }

    @Test("1 MiB を超える要求は断る。ちょうど上限の ops 1000 個と、ペンの点 10000 は通る")
    func sizeLimits() throws {
        #expect({ if case .failure(let e) = OpsParser.parse(Data(count: OpsParser.maxBytes + 1)) { return e.code == .invalidOps } else { return false } }())
        let thousand = wrap(Array(repeating: #"{"op":"pen","points":[[1,1]]}"#, count: 1000).joined(separator: ","))
        #expect(try parse(thousand).get().count == 1000)
        let points = Array(repeating: "[1,1]", count: 10_000).joined(separator: ",")
        #expect(try parse(wrap(#"{"op":"pen","points":["# + points + "]}")).get().count == 1)
    }
}

@Suite("操作を要素にする（丸め・省く・画像）")
struct OpsApplyTests {
    private let canvas = CGSize(width: 480, height: 320)
    private let pen: Op = .pen(points: [CGPoint(x: 1, y: 1)], color: .black, size: 4)

    private func apply(_ ops: [Op], loader: @escaping (String) -> ImportedImage? = { _ in nil }) throws -> OpsResult {
        try OpsApply.items(from: ops, canvas: canvas, loadImage: loader).get()
    }

    private func image(_ w: CGFloat, _ h: CGFloat) -> ImportedImage {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ImportedImage(cgImage: ctx.makeImage()!, pointSize: CGSize(width: w, height: h))
    }

    @Test("ペンの点と直線の両端が、キャンバスの縁に丸まり、丸めた操作の番号が返る。丸めなかった操作は返らない")
    func clampsPointsAndReportsThem() throws {
        let r = try apply([
            pen,
            .pen(points: [CGPoint(x: -5, y: 100), CGPoint(x: 600, y: 400)], color: .black, size: 4),
            .line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 700, y: 10), color: .black, size: 4),
        ])
        #expect(r.items.count == 3)
        #expect(r.clamped == [1, 2])
        #expect(r.skipped.isEmpty)
        guard case .pen(let points) = r.items[1].content, case .line(_, let to) = r.items[2].content else { Issue.record("種類が違う"); return }
        #expect(points.map(\.point) == [CGPoint(x: 0, y: 100), CGPoint(x: 480, y: 320)])
        #expect(to == CGPoint(x: 480, y: 10))
    }

    @Test("図形は、四隅を丸める。一部が外なら、縁までの大きさになり、まるごと外なら、足さずに skipped で返す")
    func shapesAreClampedOrSkipped() throws {
        let partly = Op.rect(rect: CGRect(x: -10, y: 300, width: 50, height: 100), color: .black, size: 4)   // 左と下に出る
        let outside = Op.ellipse(rect: CGRect(x: 500, y: 10, width: 40, height: 40), color: .black, size: 4)   // 右の外にまるごと
        let lineOutside = Op.line(from: CGPoint(x: -50, y: -50), to: CGPoint(x: -10, y: -30), color: .black, size: 4)   // 両端が左上の角に丸まる
        let r = try apply([partly, outside, lineOutside, pen])
        #expect(r.items.count == 2)                      // partly と pen
        #expect(r.skipped == [1, 2])
        #expect(r.clamped == [0, 1, 2])                  // 足さなかったものも、丸めた操作に数える
        guard case .rect(let box) = r.items[0].content else { Issue.record("種類が違う"); return }
        #expect(box == CGRect(x: 0, y: 300, width: 40, height: 20))
    }

    @Test("文字は、開始点だけを丸める。大きさは変えない")
    func textClampsOnlyTheStart() throws {
        let r = try apply([.text("abc", at: CGPoint(x: 9999, y: -3), color: .black, fontSize: 24)])
        #expect(r.clamped == [0])
        guard case .text(_, let box) = r.items[0].content else { Issue.record("種類が違う"); return }
        #expect(box.origin == CGPoint(x: 480, y: 0))
        #expect(box.width > 0 && box.height >= 24)
        #expect(r.items[0].size == 24)
    }

    @Test("画像の大きさ：省くと自然な大きさ（大きければ収まるよう縮小。拡大しない）。片方だけなら縦横比を保つ。両方ならそのまま")
    func imageSizes() throws {
        let small = try apply([.image(path: "a", at: CGPoint(x: 10, y: 20), width: nil, height: nil)], loader: { _ in self.image(200, 100) })
        guard case .image(_, let b1) = small.items[0].content else { Issue.record("種類が違う"); return }
        #expect(b1 == CGRect(x: 10, y: 20, width: 200, height: 100))

        let big = try apply([.image(path: "a", at: .zero, width: nil, height: nil)], loader: { _ in self.image(960, 640) })
        guard case .image(_, let b2) = big.items[0].content else { Issue.record("種類が違う"); return }
        #expect(b2.size == CGSize(width: 480, height: 320))        // キャンバスに収まる

        let wOnly = OpsApply.imageBox(natural: CGSize(width: 200, height: 100), at: .zero, width: 100, height: nil, canvas: canvas)
        #expect(wOnly.size == CGSize(width: 100, height: 50))
        let hOnly = OpsApply.imageBox(natural: CGSize(width: 200, height: 100), at: .zero, width: nil, height: 50, canvas: canvas)
        #expect(hOnly.size == CGSize(width: 100, height: 50))
        let both = OpsApply.imageBox(natural: CGSize(width: 200, height: 100), at: .zero, width: 30, height: 90, canvas: canvas)
        #expect(both.size == CGSize(width: 30, height: 90))
    }

    @Test("読めない画像は、何番目の操作かを示して io で断り、何も足さない。開始点は丸める")
    func imageFailuresAndClamp() throws {
        guard case .failure(let error) = OpsApply.items(from: [pen, .image(path: "/nope.png", at: .zero, width: nil, height: nil)], canvas: canvas, loadImage: { _ in nil }) else {
            Issue.record("通ってしまった"); return
        }
        #expect(error.code == .io)
        #expect(error.exitCode == 4)
        #expect(error.op == 1)

        let r = try apply([.image(path: "a", at: CGPoint(x: -20, y: 900), width: 40, height: 40)], loader: { _ in self.image(10, 10) })
        guard case .image(_, let box) = r.items[0].content else { Issue.record("種類が違う"); return }
        #expect(box == CGRect(x: 0, y: 320, width: 40, height: 40))   // 大きさは変えない
        #expect(r.clamped == [0])
    }

    @Test("要素は、操作の順に並ぶ")
    func orderIsKept() throws {
        let r = try apply([
            .rect(rect: CGRect(x: 1, y: 1, width: 5, height: 5), color: .black, size: 4),
            .line(from: .zero, to: CGPoint(x: 9, y: 9), color: .black, size: 4),
            .ellipse(rect: CGRect(x: 1, y: 1, width: 5, height: 5), color: .black, size: 4),
        ])
        let kinds = r.items.map { item -> String in
            switch item.content { case .rect: "rect"; case .line: "line"; case .ellipse: "ellipse"; default: "?" }
        }
        #expect(kinds == ["rect", "line", "ellipse"])
    }
}

@Suite("画像を置く枠")
struct PlacementTests {
    @Test("小さい画像は、拡大せず、中央。大きい画像は、縦横比を保って収まり、中央")
    func fitted() {
        #expect(Placement.fitted(CGSize(width: 100, height: 50), in: CGSize(width: 480, height: 320)) == CGRect(x: 190, y: 135, width: 100, height: 50))
        #expect(Placement.fitted(CGSize(width: 960, height: 320), in: CGSize(width: 480, height: 320)) == CGRect(x: 0, y: 80, width: 480, height: 160))
    }
}
