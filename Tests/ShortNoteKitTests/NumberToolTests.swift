import AppKit
import Testing
@testable import ShortNoteKit

@Suite("番号の印：規則（SPEC §3.2.8）")
struct NumberBadgeRuleTests {
    private func badge(_ x: CGFloat) -> Item { Item(content: .number(NumberBadge.box(center: CGPoint(x: x, y: 50), diameter: 24)), color: CGColor(gray: 0, alpha: 1), size: 0) }
    private func line() -> Item { Item(content: .line(from: .zero, to: CGPoint(x: 10, y: 10)), color: CGColor(gray: 0, alpha: 1), size: 4) }

    @Test("数字は、番号の印だけを、重なり順（奥から）に 1・2・3…。ほかの要素は数えない")
    func numbersFollowTheStackingOrder() {
        let items = [badge(10), line(), badge(60), badge(110)]
        #expect(NumberBadge.numbers(in: items) == [1, nil, 2, 3])
        #expect(NumberBadge.count(in: items) == 3)
    }

    @Test("1 つ消すと、あとの数字が詰まる（保存した数字を持たない）")
    func removingRenumbers() {
        var items = [badge(10), badge(60), badge(110)]
        items.remove(at: 0)
        #expect(NumberBadge.numbers(in: items) == [1, 2])
    }

    @Test("丸の直径：キャンバスの短い辺の 1/24、22 pt 以上")
    func diameter() {
        #expect(NumberBadge.diameter(forCanvas: CGSize(width: 480, height: 320)) == 22)
        #expect(NumberBadge.diameter(forCanvas: CGSize(width: 1920, height: 1080)) == 45)
        #expect(NumberBadge.diameter(forCanvas: CGSize(width: 1080, height: 1920)) == 45)
    }

    @Test("数字は、丸の色が白に近いときだけ暗い色")
    func darkNumeral() {
        #expect(NumberBadge.usesDarkNumeral(red: 1, green: 1, blue: 1))
        #expect(!NumberBadge.usesDarkNumeral(red: 0.9, green: 0.1, blue: 0.1))
        #expect(!NumberBadge.usesDarkNumeral(red: 0, green: 0, blue: 0))
    }
}

@Suite("番号の印：キャンバス・描画・消しゴム・取っ手")
@MainActor
struct NumberCanvasTests {
    private func mouse(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func click(_ c: CanvasView, at p: CGPoint) throws {
        c.mouseDown(with: try mouse(.leftMouseDown, c, p))
        c.mouseUp(with: try mouse(.leftMouseUp, c, p))
    }

    private func boxes(_ c: CanvasView) -> [CGRect] {
        c.document.items.compactMap { if case .number(let box) = $0.content { return box }; return nil }
    }

    @Test("番号のツールで、クリックすると、その位置が中心の印が置かれる。色は色選択の色、直径はキャンバスの大きさから。2 回目の印の数字は 2。取り消しで消える")
    func clickPlacesBadges() throws {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.tool = .number
        c.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        try click(c, at: CGPoint(x: 100, y: 80))
        try click(c, at: CGPoint(x: 200, y: 150))
        #expect(boxes(c) == [NumberBadge.box(center: CGPoint(x: 100, y: 80), diameter: 22), NumberBadge.box(center: CGPoint(x: 200, y: 150), diameter: 22)])
        #expect(NumberBadge.numbers(in: c.document.items) == [1, 2])
        #expect(ItemEncoder.hex(c.document.items[0].color) == "#FF0000")
        c.undo()
        #expect(boxes(c).count == 1 && NumberBadge.numbers(in: c.document.items) == [1])
    }

    @Test("押したまま動かすと、離すまで位置を調整できる（1 回で取り消しの 1 段）。キャンバスの外は、縁に丸める")
    func dragAdjustsThePosition() throws {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.tool = .number
        c.mouseDown(with: try mouse(.leftMouseDown, c, CGPoint(x: 100, y: 80)))
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, CGPoint(x: 140, y: 120)))
        c.mouseUp(with: try mouse(.leftMouseUp, c, CGPoint(x: 140, y: 120)))
        #expect(boxes(c) == [NumberBadge.box(center: CGPoint(x: 140, y: 120), diameter: 22)])
        c.undo()
        #expect(boxes(c).isEmpty)

        try click(c, at: CGPoint(x: 600, y: -40))   // キャンバスの外
        #expect(boxes(c) == [NumberBadge.box(center: CGPoint(x: 480, y: 0), diameter: 22)])
    }

    @Test("描画：丸は色で塗られ、数字（白）が中に出る。1 つ目を消すと、2 つ目の数字が 2 から 1 に変わる")
    func rendering() throws {
        let size = CGSize(width: 200, height: 100)
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        func item(_ x: CGFloat) -> Item { Item(content: .number(NumberBadge.box(center: CGPoint(x: x, y: 50), diameter: 40)), color: red, size: 0) }
        func render(_ items: [Item]) throws -> NSBitmapImageRep {
            var document = Document()
            for i in items { document = document.appending(i) }
            let data = try #require(CanvasRenderer.pngData(document, size: size, transparent: false))
            return try #require(NSBitmapImageRep(data: data))
        }
        let both = try render([item(50), item(150)])
        let scale = CGFloat(both.pixelsWide) / size.width
        func px(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor { rep.colorAt(x: Int(x * scale), y: Int(y * scale)) ?? .clear }
        // 丸の縁の内側（数字から離れた所）は、赤。丸の外は、白（背景）
        let edge = px(both, 150 + 17, 50)
        #expect(edge.redComponent > 0.9 && edge.greenComponent < 0.2)
        let outside = px(both, 150 + 28, 50)
        #expect(outside.redComponent > 0.9 && outside.greenComponent > 0.9)
        // 丸の中に、白い画素（数字）がある
        func whiteCount(_ rep: NSBitmapImageRep, around x: CGFloat) -> Int {
            var n = 0
            for dy in stride(from: -12 as CGFloat, through: 12, by: 1) {
                for dx in stride(from: -10 as CGFloat, through: 10, by: 1) {
                    let c = px(rep, x + dx, 50 + dy)
                    if c.greenComponent > 0.9 && c.blueComponent > 0.9 { n += 1 }
                }
            }
            return n
        }
        #expect(whiteCount(both, around: 150) > 15)
        // 1 つ目を消す：残った印の数字が、2 から 1 に変わる（同じ位置の画素が変わる）
        let only = try render([item(150)])
        #expect(whiteCount(only, around: 150) != whiteCount(both, around: 150) || only.representation(using: .png, properties: [:]) != both.representation(using: .png, properties: [:]))
        let regionBoth = (0..<Int(24 * scale)).map { px(both, 138 + CGFloat($0) / scale, 50) }
        let regionOnly = (0..<Int(24 * scale)).map { px(only, 138 + CGFloat($0) / scale, 50) }
        #expect(regionBoth != regionOnly)
    }

    @Test("消しゴム：丸の中をなぞると消え、丸から離れた所をなぞっても消えない。取っ手：縦横比を保って大きさを変える対象になり、移動ツールで掴める")
    func eraserAndHandles() throws {
        var document = Document()
        document = document.appending(Item(content: .number(NumberBadge.box(center: CGPoint(x: 100, y: 100), diameter: 30)), color: CGColor(gray: 0, alpha: 1), size: 0))
        let item = document.items[0]
        #expect(item.isTouched(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 101, y: 100), radius: 8))
        #expect(!item.isTouched(from: CGPoint(x: 160, y: 160), to: CGPoint(x: 170, y: 160), radius: 8))
        let target = try #require(document.resizeTarget(at: 0))
        #expect(target.kind == .number && target.keepsAspect)
        #expect(document.topItemIndex(at: CGPoint(x: 100, y: 100)) == 0)
    }

    @Test("大きさの変更で、直径が上限（200 pt）を超える形は受け付けない（get を、そのまま draw に渡せる）。上限までは受け付ける")
    func diameterIsCapped() throws {
        var document = Document()
        document = document.appending(Item(content: .number(NumberBadge.box(center: CGPoint(x: 100, y: 100), diameter: 30)), color: CGColor(gray: 0, alpha: 1), size: 0))
        #expect(document.applying(.box(NumberBadge.box(center: CGPoint(x: 100, y: 100), diameter: 200), rotation: 0), toItemAt: 0) != nil)
        #expect(document.applying(.box(NumberBadge.box(center: CGPoint(x: 100, y: 100), diameter: 201), rotation: 0), toItemAt: 0) == nil)
    }
}

@Suite("番号の印：操作の JSON と get（SPEC §3.7）")
struct NumberOpsTests {
    private func parse(_ ops: String) -> Result<[Op], AgentError> {
        OpsParser.parse(Data(#"{"version":1,"ops":[\#(ops)]}"#.utf8))
    }

    @Test("number：中心 x・y が必須。color・d・rotate は任意。d を省くと、キャンバスの大きさから決める。範囲外の中心は、縁に丸める")
    func parseAndApply() throws {
        let ops = try parse(##"{"op":"number","x":100,"y":80,"color":"#FF0000"},{"op":"number","x":600,"y":-5,"d":40,"rotate":90}"##).get()
        #expect(ops.count == 2)
        let result = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get()
        #expect(result.items.count == 2 && result.clamped == [1] && result.skipped.isEmpty)
        guard case .number(let first) = result.items[0].content, case .number(let second) = result.items[1].content else { Issue.record("番号の印でない"); return }
        #expect(first == NumberBadge.box(center: CGPoint(x: 100, y: 80), diameter: 22))
        #expect(second == NumberBadge.box(center: CGPoint(x: 480, y: 0), diameter: 40))
        #expect(abs(result.items[1].rotation - .pi / 2) < 1e-9)
    }

    @Test("不正：x・y がない、d が範囲外、size・fill・w など、知らない項目は、エラー（何番目の操作かを付ける）")
    func invalid() {
        for bad in [#"{"op":"number","x":10}"#, #"{"op":"number","x":10,"y":10,"d":7}"#, #"{"op":"number","x":10,"y":10,"d":201}"#,
                    #"{"op":"number","x":10,"y":10,"size":4}"#, #"{"op":"number","x":10,"y":10,"fill":true}"#, #"{"op":"number","x":10,"y":10,"color":"red"}"#] {
            if case .success = parse(bad) { Issue.record("通ってしまった：\(bad)") }
        }
    }

    @Test("get の要素（number）は、そのまま draw に渡せる：読み直すと、同じ印になる。数字は返さない")
    func roundTrip() throws {
        let item = Item(content: .number(NumberBadge.box(center: CGPoint(x: 120.5, y: 64), diameter: 30)), color: CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1), size: 0, rotation: .pi / 4)
        var json = ItemEncoder.json(item, index: 3)
        #expect(json["op"] as? String == "number" && json["d"] != nil && json["number"] == nil)
        json.removeValue(forKey: "index")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "ops": [json]])
        let ops = try OpsParser.parse(data).get()
        let back = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get().items
        #expect(back.count == 1 && back[0].hasSameGeometry(as: item))
        #expect(ItemEncoder.hex(back[0].color) == ItemEncoder.hex(item.color))
    }
}

@Suite("番号のツール：キー")
struct NumberToolKeyTests {
    @Test("既定のキーは 0。ほかのツールのキー（1〜9）・ビューを戻す（Cmd+0）と重ならない")
    func defaultKey() {
        let b = KeyBindings()
        #expect(b.command(for: KeyChord(keyCode: 29, label: "0"), whileEditingText: false) == .toolNumber)
        #expect(b.command(for: KeyChord(keyCode: 29, modifiers: .command, label: "0"), whileEditingText: false) == .viewReset)
        #expect(Command.toolNumber.group == .tool && Command.toolNumber.title == "ツール: 番号")
    }
}
