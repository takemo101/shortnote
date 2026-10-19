import AppKit
import Testing
@testable import ShortNoteKit

private func allSubviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allSubviews) }

private func pixel(_ png: Data, _ x: Int, _ y: Int) throws -> (r: Double, g: Double, b: Double, a: Double) {
    let rep = try #require(NSBitmapImageRep(data: png))
    let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
}

private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

@Suite("円・四角の塗りつぶし：描画")
struct FillRenderTests {
    /// 480x320 pt のキャンバス（書き出しは 2 倍）に、1 つの要素を描いた PNG。
    private func png(_ item: Item) throws -> Data {
        try #require(CanvasRenderer.pngData(Document(items: [item]), size: CGSize(width: 480, height: 320), transparent: false))
    }

    @Test("塗りつぶした四角は、内側が色で塗られる。枠だけは、内側が白のまま")
    func filledRectIsPainted() throws {
        let box = CGRect(x: 100, y: 100, width: 120, height: 80)
        let filled = try png(Item(content: .rect(box), color: red, size: 4, filled: true))
        let outline = try png(Item(content: .rect(box), color: red, size: 4))
        let inside = (x: 320, y: 280)   // 内側の中心（2 倍の画素）
        #expect(try pixel(filled, inside.x, inside.y).g < 0.2 && pixel(filled, inside.x, inside.y).r > 0.9)
        #expect(try pixel(outline, inside.x, inside.y).g > 0.9)
        #expect(try pixel(filled, 190, 190).g > 0.9)   // 外形（線の太さを含む）の外は、塗られない
    }

    @Test("塗りつぶした円は、外接する四角の角（円の外）が塗られず、中心が塗られる")
    func filledEllipseIsRound() throws {
        let box = CGRect(x: 100, y: 100, width: 120, height: 120)
        let filled = try png(Item(content: .ellipse(box), color: red, size: 4, filled: true))
        #expect(try pixel(filled, 320, 320).r > 0.9 && pixel(filled, 320, 320).g < 0.2)     // 中心
        #expect(try pixel(filled, 208, 208).g > 0.9)                                          // 左上の角の近く（円の外）
    }

    @Test("透明度のある色でも、塗りと枠の重なりが濃くならない（内側と枠の画素が同じ）")
    func translucentFillIsUniform() throws {
        let half = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        let data = try png(Item(content: .rect(CGRect(x: 100, y: 100, width: 120, height: 80)), color: half, size: 12, filled: true))
        let inside = try pixel(data, 320, 280)
        let onTheEdge = try pixel(data, 200, 280)   // 左の辺（線の真ん中）の上
        #expect(abs(inside.g - onTheEdge.g) < 0.03 && abs(inside.r - onTheEdge.r) < 0.03, "inside=\(inside) edge=\(onTheEdge)")
        #expect(inside.g > 0.4 && inside.g < 0.6)   // 白に、半分の赤
    }

    @Test("移動しても、塗りつぶしは保たれる")
    func translatingKeepsTheFill() {
        let item = Item(content: .ellipse(CGRect(x: 0, y: 0, width: 10, height: 10)), color: red, size: 2, filled: true)
        #expect(item.translated(by: CGSize(width: 5, height: 5)).filled)
    }
}

@Suite("円・四角の塗りつぶし：操作の JSON")
struct FillOpsTests {
    private func parse(_ ops: String) -> Result<[Op], AgentError> { OpsParser.parse(Data("{\"version\":1,\"ops\":[\(ops)]}".utf8)) }

    @Test("fill は、true・false。省くと false。ellipse と rect だけ")
    func parsesFill() throws {
        let ops = try parse(#"{"op":"rect","x":1,"y":2,"w":3,"h":4,"fill":true},{"op":"ellipse","x":1,"y":2,"w":3,"h":4,"fill":false},{"op":"ellipse","x":1,"y":2,"w":3,"h":4}"#).get()
        #expect(ops[0] == .rect(rect: CGRect(x: 1, y: 2, width: 3, height: 4), color: .black, size: 4, fill: true))
        #expect(ops[1] == .ellipse(rect: CGRect(x: 1, y: 2, width: 3, height: 4), color: .black, size: 4, fill: false))
        #expect(ops[2] == ops[1])
        guard case .failure(let error) = parse(#"{"op":"line","from":[0,0],"to":[5,5],"fill":true}"#) else { Issue.record("line に fill が通った"); return }
        #expect(error.code == .invalidOps && error.op == 0)
    }

    @Test("fill が真偽値でないものは、何番目かを付けて断る（0・1・文字列・null）")
    func rejectsNonBooleanFill() {
        for bad in ["1", "0", "\"true\"", "null", "2.5", "[]"] {
            guard case .failure(let error) = parse(#"{"op":"rect","x":1,"y":1,"w":9,"h":9},{"op":"ellipse","x":1,"y":2,"w":3,"h":4,"fill":\#(bad)}"#) else { Issue.record("通った：\(bad)"); continue }
            #expect(error.code == .invalidOps && error.op == 1, "\(bad)")
        }
    }

    @Test("適用すると、要素の filled になる。get の JSON に fill が出て、読み直すと同じ操作に戻る")
    func appliesAndEncodes() throws {
        let ops: [Op] = [
            .rect(rect: CGRect(x: 10, y: 10, width: 50, height: 40), color: RGBA(hex: "#FF0000")!, size: 4, fill: true),
            .ellipse(rect: CGRect(x: 70, y: 10, width: 50, height: 40), color: RGBA(hex: "#00FF00")!, size: 4, fill: false),
        ]
        let items = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get().items
        #expect(items.map(\.filled) == [true, false])
        let json = items.enumerated().map { ItemEncoder.json($1, index: $0) }
        #expect(json[0]["fill"] as? Bool == true && json[1]["fill"] as? Bool == false)
        #expect(json[0]["op"] as? String == "rect" && json[1]["op"] as? String == "ellipse")
        for (item, op) in zip(items, ops) {
            var j = ItemEncoder.json(item, index: 0); j["index"] = nil
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "ops": [j]])
            #expect(try OpsParser.parse(data).get().first == op)
        }
    }

    @Test("丸めて大きさがなくなった塗りつぶしは、枠と同じく skipped")
    func clampedFillIsSkippedLikeAnOutline() throws {
        let result = try OpsApply.items(from: [.rect(rect: CGRect(x: 500, y: 10, width: 40, height: 40), color: .black, size: 4, fill: true)], canvas: CGSize(width: 480, height: 320)).get()
        #expect(result.items.isEmpty && result.skipped == [0])
    }
}

@Suite("円・四角の塗りつぶし：キャンバスとツールバー")
@MainActor
struct FillUITests {
    private func mouse(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(_ canvas: CanvasView, from a: CGPoint, to b: CGPoint) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, canvas, a))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, canvas, b))
        canvas.mouseUp(with: try mouse(.leftMouseUp, canvas, b))
    }

    @Test("円と四角の塗りつぶしは別々。選びのとおりに、確定した図形が filled になり、取り消せる")
    func canvasUsesTheChoicePerTool() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.fillEllipse = true
        canvas.tool = .ellipse
        try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90))
        canvas.tool = .rect
        try drag(canvas, from: CGPoint(x: 200, y: 20), to: CGPoint(x: 300, y: 90))
        canvas.fillRect = true
        try drag(canvas, from: CGPoint(x: 200, y: 120), to: CGPoint(x: 300, y: 190))
        #expect(canvas.document.items.map(\.filled) == [true, false, true])
        canvas.undo()
        #expect(canvas.document.items.map(\.filled) == [true, false])
    }

    @Test("ツールバー：図形のボタンに、2 列 × 3 行のメニュー（左が枠だけ、右が塗りつぶし。上から 四角・円・三角）。マスを選ぶと、通知・印・ツールの切り替えが起きる。選びは図形ごとに別々")
    func shapeMenu() throws {
        let toolbar = Toolbar()
        let control = try #require(allSubviews(toolbar.topRow).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 6 })
        #expect(control.menu(forSegment: Toolbar.segment(for: .pen)) == nil)
        let shapeSegment = Toolbar.segment(for: .ellipse)
        let menu = try #require(control.menu(forSegment: shapeSegment))
        let grid = try #require(menu.items.first?.view as? ShapeMenuView)
        #expect(menu.items.count == 1 && control.showsMenuIndicator(forSegment: shapeSegment) && !control.showsMenuIndicator(forSegment: Toolbar.segment(for: .pen)))

        func cell(_ id: String) throws -> NSButton {
            try #require(allSubviews(grid).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id })
        }
        // 配置：左の列が枠だけ、右の列が塗りつぶし。上から 四角・円・三角（座標は、下が 0）
        let ids = ["shape-rect-outline", "shape-rect-fill", "shape-ellipse-outline", "shape-ellipse-fill", "shape-triangle-outline", "shape-triangle-fill"]
        let frames = try ids.map { try cell($0).frame }
        #expect(frames.count == 6 && Set(frames.map(\.minX)).count == 2 && Set(frames.map(\.minY)).count == 3)
        #expect(frames[0].minX < frames[1].minX && frames[0].minY > frames[2].minY && frames[2].minY > frames[4].minY)
        // 起動のときは、枠だけの円に印
        #expect(try ids.filter { try cell($0).state == .on } == ["shape-ellipse-outline"])
        let before = control.image(forSegment: shapeSegment)?.tiffRepresentation

        var fills: [String] = [], tools: [Tool] = []
        toolbar.onSelectFill = { fills.append("\($0)=\($1)") }
        toolbar.onSelectTool = { tools.append($0) }
        control.selectedSegment = Toolbar.segment(for: .pen)

        try cell("shape-triangle-fill").performClick(nil)           // 三角：塗りつぶし
        #expect(fills == ["triangle=true"] && tools == [.triangle] && control.selectedSegment == shapeSegment)
        #expect(try ids.filter { try cell($0).state == .on } == ["shape-triangle-fill"])
        #expect(control.image(forSegment: shapeSegment)?.tiffRepresentation != before)   // ボタンの絵が、選びに合う
        try cell("shape-rect-outline").performClick(nil)            // 四角：枠だけ
        #expect(fills == ["triangle=true", "rect=false"] && tools == [.triangle, .rect])

        // ボタンを普通に押す：その図形（いま表している図形）のツールを選ぶだけで、描き方は、変えない
        control.selectedSegment = Toolbar.segment(for: .pen)
        control.sendAction(control.action, to: control.target)
        #expect(tools.last == .pen)
        control.selectedSegment = shapeSegment
        control.sendAction(control.action, to: control.target)
        #expect(tools.last == .rect && fills.count == 2)
        // キーでツールを替えると、ボタンは、その図形になり、描き方は、その図形で最後に選んだもの（三角は、塗りつぶし）
        toolbar.show(tool: .triangle)
        #expect(try ids.filter { try cell($0).state == .on } == ["shape-triangle-fill"])
        control.selectedSegment = Toolbar.segment(for: .pen)
        control.selectedSegment = shapeSegment
        control.sendAction(control.action, to: control.target)
        #expect(tools.last == .triangle)
    }
}
