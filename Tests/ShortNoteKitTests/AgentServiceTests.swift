import CoreGraphics
import Foundation
import Testing
@testable import ShortNoteKit

/// `AgentCanvas` の、記録するだけの代役。
private final class FakeCanvas: AgentCanvas {
    var agentCanvasSize = CGSize(width: 480, height: 320)
    var appended: [[Item]] = []
    var clearResult = true
    var snapshot = AgentSnapshot(size: CGSize(width: 480, height: 320), background: nil, editing: false, items: [])
    var exportURL: URL? = URL(fileURLWithPath: "/tmp/shortnote/note-test.png")

    func agentAppend(_ items: [Item]) { appended.append(items) }
    func agentClear() -> Bool { clearResult }
    func agentSnapshot() -> AgentSnapshot { snapshot }
    func agentExport() -> URL? { exportURL }
}

private func object(_ reply: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
}

private func wrap(_ ops: String) -> Data { Data("{\"version\":1,\"ops\":[\(ops)]}".utf8) }

@Suite("エージェントの要求の実行")
struct AgentServiceTests {
    private func service(_ canvas: FakeCanvas, loadImage: @escaping (String) -> ImportedImage? = { _ in nil }) -> AgentService {
        AgentService(canvas: canvas, loadImage: loadImage)
    }

    @Test("draw：要素を 1 回で足し、丸めた・足さなかった操作の番号を返す")
    func drawAppendsOnceAndReports() throws {
        let canvas = FakeCanvas()
        let body = String(decoding: wrap("""
        {"op":"rect","x":10,"y":10,"w":50,"h":40},
        {"op":"line","from":[-20,-20],"to":[-5,-5]},
        {"op":"text","x":-10,"y":5,"text":"hi"}
        """), as: UTF8.self)
        let reply = try object(service(canvas).handle(Data("draw \(body)".utf8)))
        #expect(reply["added"] as? Int == 2)
        #expect(reply["clamped"] as? [Int] == [1, 2])
        #expect(reply["skipped"] as? [Int] == [1])
        #expect(canvas.appended.count == 1 && canvas.appended[0].count == 2)   // 1 回の要求で、1 回だけ足す（取り消し 1 段）
    }

    @Test("draw：足すものが無いとき（全部、縁の外）は、足さない（取り消しの段を作らない）")
    func drawOfNothingDoesNotAppend() throws {
        let canvas = FakeCanvas()
        let reply = try object(service(canvas).handle(Data("draw ".utf8) + wrap(#"{"op":"rect","x":500,"y":10,"w":40,"h":40}"#)))
        #expect(reply["added"] as? Int == 0 && reply["skipped"] as? [Int] == [0])
        #expect(canvas.appended.isEmpty)
    }

    @Test("draw：不正な操作は、何番目かを付けて断り、何も足さない。読めない画像は io")
    func drawRejectsWithoutAppending() throws {
        let canvas = FakeCanvas()
        let bad = try object(service(canvas).handle(Data("draw ".utf8) + wrap(#"{"op":"rect","x":1,"y":1,"w":9,"h":9},{"op":"zzz"}"#)))
        let error = try #require(bad["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_ops" && error["op"] as? Int == 1)

        let image = try object(service(canvas).handle(Data("draw ".utf8) + wrap(#"{"op":"rect","x":1,"y":1,"w":9,"h":9},{"op":"image","path":"/no/such.png","x":0,"y":0}"#)))
        let ioError = try #require(image["error"] as? [String: Any])
        #expect(ioError["code"] as? String == "io" && ioError["op"] as? Int == 1)
        #expect(canvas.appended.isEmpty)   // 全部か、なしか
    }

    @Test("draw：画像は、アプリが読む。自然な大きさで、指定の位置に置かれる")
    func drawLoadsImages() throws {
        let canvas = FakeCanvas()
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cg = try #require(context.makeImage())
        let reply = try object(service(canvas, loadImage: { _ in ImportedImage(cgImage: cg, pointSize: CGSize(width: 4, height: 2)) })
            .handle(Data("draw ".utf8) + wrap(#"{"op":"image","path":"/x.png","x":7,"y":9}"#)))
        #expect(reply["added"] as? Int == 1)
        guard case .image(_, let box) = canvas.appended[0][0].content else { Issue.record("画像でない"); return }
        #expect(box == CGRect(x: 7, y: 9, width: 4, height: 2))
    }

    @Test("get：キャンバスの大きさ・背景・editing・要素（index つき）を返す。背景がなければ null")
    func getShape() throws {
        let canvas = FakeCanvas()
        canvas.snapshot = AgentSnapshot(size: CGSize(width: 480, height: 320), background: nil, editing: true, items: [
            Item(content: .rect(CGRect(x: 1, y: 2, width: 30, height: 40)), color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), size: 4),
        ])
        var reply = try object(service(canvas).handle(Data("get".utf8)))
        #expect((reply["canvas"] as? [String: Double]) == ["width": 480, "height": 320])
        #expect(reply["background"] is NSNull)
        #expect(reply["editing"] as? Bool == true)
        let items = try #require(reply["items"] as? [[String: Any]])
        #expect(items.count == 1 && items[0]["index"] as? Int == 0 && items[0]["op"] as? String == "rect" && items[0]["color"] as? String == "#FF0000")

        canvas.snapshot.background = CGRect(x: 0, y: 10, width: 480, height: 300)
        reply = try object(service(canvas).handle(Data("get".utf8)))
        #expect((reply["background"] as? [String: Double]) == ["x": 0, "y": 10, "w": 480, "h": 300])
    }

    @Test("export・clear：結果を返す。書き出せなければ io")
    func exportAndClear() throws {
        let canvas = FakeCanvas()
        #expect(try object(service(canvas).handle(Data("export".utf8)))["path"] as? String == "/tmp/shortnote/note-test.png")
        canvas.exportURL = nil
        #expect(try #require(object(service(canvas).handle(Data("export".utf8)))["error"] as? [String: Any])["code"] as? String == "io")
        #expect(try object(service(canvas).handle(Data("clear".utf8)))["cleared"] as? Bool == true)
        canvas.clearResult = false
        #expect(try object(service(canvas).handle(Data("clear".utf8)))["cleared"] as? Bool == false)
    }

    @Test("知らないコマンド・本文のあるコマンドは usage")
    func usageErrors() throws {
        let canvas = FakeCanvas()
        for request in ["", "paint", "get now", "clear all", "export x"] {
            let error = try #require(object(service(canvas).handle(Data(request.utf8)))["error"] as? [String: Any], "\(request)")
            #expect(error["code"] as? String == "usage", "\(request)")
        }
    }
}

@Suite("要素の JSON（get）")
struct ItemEncoderTests {
    /// 要素を JSON にして、`index` を除き、操作の JSON として読み直す。`get` の要素が、`draw` にそのまま渡せる形であることの確かめ。
    private func reparsed(_ item: Item) throws -> Op {
        var json = ItemEncoder.json(item, index: 0)
        json["index"] = nil
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "ops": [json]])
        return try #require(try OpsParser.parse(data).get().first)
    }

    @Test("ペン・直線・図形・文字は、操作の JSON として読み直すと、元の操作に戻る")
    func roundTripsThroughOpsParser() throws {
        let canvas = CGSize(width: 480, height: 320)
        let ops: [Op] = [
            .pen(points: [CGPoint(x: 10.5, y: 20), CGPoint(x: 30, y: 40.25)], color: RGBA(hex: "#1A2B3C")!, size: 7),
            .line(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 100, y: 50.5), color: RGBA(hex: "#FF000080")!, size: 12),
            .ellipse(rect: CGRect(x: 5, y: 6, width: 70, height: 80), color: .black, size: 4),
            .rect(rect: CGRect(x: 15, y: 16, width: 17, height: 18), color: RGBA(hex: "#00FF00")!, size: 40),
            .text("こんにちは\n2 行目", at: CGPoint(x: 9, y: 10), color: RGBA(hex: "#0000FF")!, fontSize: 24),
        ]
        let items = try OpsApply.items(from: ops, canvas: canvas).get().items
        #expect(items.count == ops.count)
        for (item, op) in zip(items, ops) { #expect(try reparsed(item) == op) }
    }

    @Test("画像：位置と大きさ。path は持たない")
    func imageHasNoPath() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = ImportedImage(cgImage: try #require(context.makeImage()), pointSize: CGSize(width: 2, height: 2))
        let json = ItemEncoder.json(Item(content: .image(image, box: CGRect(x: 3, y: 4, width: 50, height: 60)), color: CGColor(gray: 0, alpha: 1), size: 0), index: 5)
        #expect(json["op"] as? String == "image" && json["index"] as? Int == 5)
        #expect(json["x"] as? Double == 3 && json["y"] as? Double == 4 && json["w"] as? Double == 50 && json["h"] as? Double == 60)
        #expect(json["path"] == nil && json["color"] == nil)
    }

    @Test("色：sRGB の #RRGGBB、透明度があれば #RRGGBBAA。濃淡の色も出せる")
    func hexOfColors() {
        #expect(ItemEncoder.hex(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF8000")
        #expect(ItemEncoder.hex(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)) == "#00000080")
        #expect(ItemEncoder.hex(CGColor(gray: 0, alpha: 1)) == "#000000")
        #expect(ItemEncoder.hex(CGColor(gray: 1, alpha: 1)) == "#FFFFFF")
    }

    @Test("数：小数 3 桁に丸め、-0 を出さない")
    func numbers() {
        #expect(ItemEncoder.number(1.23456).stringValue == "1.235")
        #expect(ItemEncoder.number(-0.0001).stringValue == "0")
        #expect(ItemEncoder.number(10).stringValue == "10")
    }

    @Test("get の返事に出る数は、丸めた桁だけ（Double のままだと 10.300000000000001 と出る）")
    func printedNumbersAreRounded() {
        let canvas = FakeCanvas()
        canvas.snapshot = AgentSnapshot(size: CGSize(width: 480.25, height: 320), background: CGRect(x: 0, y: 0.1, width: 7, height: 9), editing: false, items: [
            Item(content: .rect(CGRect(x: 10.3, y: 1.235, width: 45.7, height: 0.1)), color: CGColor(gray: 0, alpha: 1), size: 4),
        ])
        let text = AgentService(canvas: canvas).handle(Data("get".utf8))
        for expected in ["\"x\":10.3,", "\"y\":1.235}", "\"w\":45.7,", "\"h\":0.1,", "\"width\":480.25}", "\"y\":0.1}"] {
            #expect(text.contains(expected), "\(expected) in \(text)")
        }
        #expect(!text.contains("0000000"))
    }
}
