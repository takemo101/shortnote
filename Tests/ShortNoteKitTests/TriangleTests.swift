import AppKit
import Testing
@testable import ShortNoteKit

private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let canvasRect = CGRect(x: 0, y: 0, width: 480, height: 320)

private func pixel(_ png: Data, _ x: Int, _ y: Int) throws -> (r: Double, g: Double, b: Double, a: Double) {
    let rep = try #require(NSBitmapImageRep(data: png))
    let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
}

@Suite("三角形：形・文書（A34）")
struct TriangleDocumentTests {
    @Test("頂点は上辺の中央、底辺は下辺。外接する範囲は、線の太さの分だけ広い")
    func geometry() {
        let box = CGRect(x: 10, y: 20, width: 80, height: 60)
        #expect(Triangle.points(in: box) == [CGPoint(x: 50, y: 20), CGPoint(x: 90, y: 80), CGPoint(x: 10, y: 80)])
        let item = Item(content: .triangle(box), color: red, size: 6)
        #expect(item.bounds == box.insetBy(dx: -3, dy: -3))
    }

    @Test("移動・大きさの変更・回転が、円・四角と同じに働く（取っ手の対象になり、形が変わったと判定される）")
    func behavesLikeOtherBoxShapes() throws {
        let box = CGRect(x: 100, y: 100, width: 80, height: 60)
        let doc = Document().appending(Item(content: .triangle(box), color: red, size: 4, filled: true))
        let target = try #require(doc.resizeTarget(at: 0))
        #expect(target.kind == .triangle && !target.keepsAspect)
        guard case .box(let shapeBox, let angle) = target.shape else { Issue.record("box 以外"); return }
        #expect(shapeBox == box && angle == 0)

        let resized = try #require(doc.applying(.box(CGRect(x: 100, y: 100, width: 160, height: 90), rotation: 0), toItemAt: 0))
        guard case .triangle(let r) = resized.items[0].content else { Issue.record("三角形でなくなった"); return }
        #expect(r.width == 160 && r.height == 90 && resized.items[0].filled)           // 塗りつぶしは、変わらない
        #expect(resized.hasChangedItem(at: 0, since: doc))

        let turned = try #require(doc.rotating(itemAt: 0, by: .pi / 2))
        #expect(abs(turned.items[0].rotation - .pi / 2) < 1e-9)
        guard case .triangle(let same) = turned.items[0].content else { Issue.record("三角形でなくなった"); return }
        #expect(same == box)                                                              // 枠は、そのまま（描くときに回す）
        #expect(turned.hasChangedItem(at: 0, since: doc))

        let moved = try #require(doc.translatingItems(at: [0], by: CGSize(width: 5, height: 7), keepingGrabAreaIn: canvasRect))
        guard case .triangle(let m) = moved.items[0].content else { Issue.record("三角形でなくなった"); return }
        #expect(m == box.offsetBy(dx: 5, dy: 7))
    }

    @Test("範囲選択：三角形も、すっぽり入れば選ばれる")
    func marquee() {
        let doc = Document().appending(Item(content: .triangle(CGRect(x: 100, y: 100, width: 40, height: 40)), color: red, size: 4))
        #expect(doc.itemIndices(containedIn: CGRect(x: 90, y: 90, width: 70, height: 70), canvas: canvasRect) == [0])
        #expect(doc.itemIndices(containedIn: CGRect(x: 90, y: 90, width: 30, height: 70), canvas: canvasRect).isEmpty)
    }
}

@Suite("三角形：描画（A34）")
struct TriangleRenderTests {
    private func png(_ item: Item) throws -> Data {
        try #require(CanvasRenderer.pngData(Document(items: [item]), size: CGSize(width: 480, height: 320), transparent: false))
    }

    // 枠 (100,100)-(220,200)：頂点 (160,100)、底辺 y=200。書き出しは 2 倍の画素。
    private let box = CGRect(x: 100, y: 100, width: 120, height: 100)

    @Test("塗りつぶした三角形：中心は塗られ、頂点の脇・底辺の両端の上（三角形の外）は塗られない")
    func filledShape() throws {
        let data = try png(Item(content: .triangle(box), color: red, size: 2, filled: true))
        #expect(try pixel(data, 320, 340).r > 0.9 && pixel(data, 320, 340).g < 0.2)       // 中心 (160,170)
        #expect(try pixel(data, 208, 210).g > 0.9)                                         // 左上の角の近く (104,105)：外
        #expect(try pixel(data, 432, 210).g > 0.9)                                         // 右上の角の近く：外
        #expect(try pixel(data, 320, 380).r > 0.9)                                         // 底辺の近くの内側 (160,190)
    }

    @Test("枠だけの三角形：内側は白のまま。頂点と底辺に線が出る")
    func outlineShape() throws {
        let data = try png(Item(content: .triangle(box), color: red, size: 4))
        #expect(try pixel(data, 320, 340).g > 0.9)                                         // 中心は白
        #expect(try pixel(data, 320, 400).g < 0.2)                                         // 底辺の線 (160,200)
        #expect(try pixel(data, 320, 204).g < 0.3)                                         // 頂点 (160,102) の近く
    }

    @Test("回した三角形：頂点が、上でなく、右に向く（90°。時計回り）")
    func rotated() throws {
        let data = try png(Item(content: .triangle(box), color: red, size: 2, filled: true, rotation: .pi / 2))
        // 枠の中心 (160,150) を軸に 90° 回る。頂点 (160,100) → (210,150)。底辺は、x = 110 の縦の辺になる。
        #expect(try pixel(data, 2 * 205, 2 * 150).g < 0.3)                                 // 頂点の近く
        #expect(try pixel(data, 2 * 115, 2 * 150).g < 0.3)                                 // 底辺の近く（内側）
        #expect(try pixel(data, 2 * 160, 2 * 102).g > 0.9)                                 // 元の頂点の位置は、外
    }
}

@Suite("三角形：操作の JSON（A34）")
struct TriangleOpsTests {
    private func parse(_ ops: String) -> Result<[Op], AgentError> { OpsParser.parse(Data("{\"version\":1,\"ops\":[\(ops)]}".utf8)) }

    @Test("triangle：ellipse・rect と同じ項目（fill・rotate を含む）。知らない項目・大きさのない指定は、エラー")
    func parsing() throws {
        let ok = try parse(##"{"op":"triangle","x":10,"y":20,"w":80,"h":60,"color":"#ff0000","size":3,"fill":true,"rotate":45}"##).get()
        #expect(ok == [.triangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: RGBA(hex: "#ff0000")!, size: 3, fill: true, rotate: 45)])
        #expect(throws: Never.self) { try parse(##"{"op":"triangle","x":0,"y":0,"w":1,"h":1}"##).get() }
        for bad in [##"{"op":"triangle","x":0,"y":0,"w":0.5,"h":10}"##, ##"{"op":"triangle","x":0,"y":0,"w":10,"h":10,"fill":1}"##, ##"{"op":"triangle","x":0,"y":0,"w":10,"h":10,"arrow":"end"}"##] {
            guard case .failure = parse(bad) else { Issue.record("通ってしまった：\(bad)"); continue }
        }
    }

    @Test("適用：三角形の要素（塗り・回転つき）になり、get の JSON が draw に戻せる（往復）")
    func roundTrip() throws {
        let ops = try parse(##"{"op":"triangle","x":10,"y":20,"w":80,"h":60,"fill":true,"rotate":30}"##).get()
        let applied = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get()
        let item = try #require(applied.items.first)
        guard case .triangle(let box) = item.content else { Issue.record("三角形でない"); return }
        #expect(box == CGRect(x: 10, y: 20, width: 80, height: 60) && item.filled && abs(item.rotation - .pi / 6) < 1e-9)

        let json = ItemEncoder.json(item, index: 0)
        #expect(json["op"] as? String == "triangle" && json["fill"] as? Bool == true)
        #expect((json["rotate"] as? NSDecimalNumber)?.doubleValue == 30)
        var back = json; back.removeValue(forKey: "index")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "ops": [back]])
        let again = try OpsParser.parse(data).get()
        #expect(again == ops)
    }

    @Test("範囲の外へはみ出した三角形は、縁に丸める。まるごと外なら、足さずに skipped")
    func clamping() throws {
        let ops = try parse(##"{"op":"triangle","x":400,"y":250,"w":200,"h":200},{"op":"triangle","x":900,"y":900,"w":10,"h":10}"##).get()
        let applied = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get()
        #expect(applied.items.count == 1 && applied.skipped == [1])
        guard case .triangle(let box) = applied.items[0].content else { Issue.record("三角形でない"); return }
        #expect(box == CGRect(x: 400, y: 250, width: 80, height: 70))
    }
}

@Suite("三角形：キャンバス（A34）")
@MainActor
struct TriangleCanvasTests {
    private func mouse(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(_ canvas: CanvasView, from a: CGPoint, to b: CGPoint) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, canvas, a))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, canvas, b))
        canvas.mouseUp(with: try mouse(.leftMouseUp, canvas, b))
    }

    @Test("三角形のツール：ドラッグした四角が、枠になる（右下から左上へ引いても同じ）。塗りは、三角形の選びのとおり。取り消せる。大きさのないものは、足さない")
    func drawing() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        canvas.tool = .triangle
        try drag(canvas, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 200, y: 150))
        canvas.fillTriangle = true
        try drag(canvas, from: CGPoint(x: 400, y: 250), to: CGPoint(x: 300, y: 200))
        try drag(canvas, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        #expect(canvas.document.items.count == 2)
        guard case .triangle(let a) = canvas.document.items[0].content, case .triangle(let b) = canvas.document.items[1].content else { Issue.record("三角形でない"); return }
        #expect(a == CGRect(x: 100, y: 50, width: 100, height: 100) && b == CGRect(x: 300, y: 200, width: 100, height: 50))
        #expect(canvas.document.items.map(\.filled) == [false, true])
        canvas.undo()
        #expect(canvas.document.items.count == 1)
    }
}

@Suite("図形のメニュー：ボタンの幅・離して選ぶ（レビューの指摘）")
@MainActor
struct ShapeMenuBehaviourTests {
    private func allSubviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allSubviews) }

    @Test("どのマスを選んでも、図形のボタンの幅・ツールバーの上段の幅は変わらない（絵の大きさが、円・四角・三角でまちまちでも）")
    func widthIsConstant() throws {
        let toolbar = Toolbar()
        let control = try #require(allSubviews(toolbar.topRow).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 7 })
        let grid = try #require(control.menu(forSegment: Toolbar.segment(for: .ellipse))?.items.first?.view as? ShapeMenuView)
        let cells = allSubviews(grid).compactMap { $0 as? NSButton }
        #expect(cells.count == 6)
        let widthBefore = control.intrinsicContentSize.width, rowBefore = toolbar.topRow.fittingSize.width
        #expect(rowBefore <= CanvasView.minimumSize.width, "上段が、キャンバスの最小（480 pt）を超えた：\(rowBefore)")
        for cell in cells {
            cell.performClick(nil)
            #expect(control.intrinsicContentSize.width == widthBefore && toolbar.topRow.fittingSize.width == rowBefore, "\(cell.accessibilityIdentifier()) で幅が変わった")
        }
    }

    @Test("ボタンを押したままメニューを開き、マスの上で離したとき（mouseUp だけが届く）も、そのマスが選ばれる。普通に押して離す（mouseDown の追跡の中）では、二重に選ばない")
    func releaseOnACellSelectsIt() throws {
        _ = NSApplication.shared   // `sendAction` は、アプリのオブジェクトを通す。ほかのテストが先に作っていないと（CI の順序では）、何も送られない
        let grid = ShapeMenuView()
        var chosen: [String] = []
        grid.onChoose = { chosen.append("\(ShapeMenuView.title(for: $0))\($1 ? "・塗り" : "")") }
        let cell = try #require(allSubviews(grid).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "shape-triangle-fill" })
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        cell.mouseUp(with: up)
        #expect(chosen == ["三角・塗り"])
    }
}
