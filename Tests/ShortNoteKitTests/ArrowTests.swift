import AppKit
import Testing
@testable import ShortNoteKit

private let black = CGColor(gray: 0, alpha: 1)

private func lineItem(_ a: CGPoint, _ b: CGPoint, size: CGFloat = 4, arrow: Item.Arrow = .none) -> Item {
    Item(content: .line(from: a, to: b), color: black, size: size, arrow: arrow)
}

private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tolerance }

@Suite("矢印（直線の派生）：形と描画（A32）")
@MainActor
struct ArrowShapeTests {
    @Test("矢じり：端から、線の反対向きへ、左右 28° に開いた 2 本。長さは 10 + 太さ × 2.5")
    func armsGeometry() {
        // 水平な直線（0,0）→（100,0）の、終点（100,0）。線の向きは、終点から始点へ（-x）
        let arms = Arrowhead.arms(tip: CGPoint(x: 100, y: 0), other: CGPoint(x: 0, y: 0), size: 4)
        let length: CGFloat = 10 + 4 * 2.5
        let c = cos(28 * CGFloat.pi / 180), s = sin(28 * CGFloat.pi / 180)
        #expect(arms.count == 2)
        #expect(near(arms[0], CGPoint(x: 100 - length * c, y: -length * s)))     // 上側（y が下向きなので、y は負）
        #expect(near(arms[1], CGPoint(x: 100 - length * c, y: length * s)))      // 下側
        // 向きが変わっても、長さと開きは同じ（斜めの直線）
        let diagonal = Arrowhead.arms(tip: CGPoint(x: 50, y: 50), other: CGPoint(x: 0, y: 0), size: 4)
        #expect(diagonal.allSatisfy { abs(hypot($0.x - 50, $0.y - 50) - length) < 1e-9 })
    }

    @Test("矢じりの長さは、直線の長さの 2/3 まで。長さのない直線には、矢じりがない")
    func armLengthIsCapped() {
        let short = Arrowhead.arms(tip: CGPoint(x: 12, y: 0), other: .zero, size: 4)
        #expect(short.allSatisfy { abs(hypot($0.x - 12, $0.y) - 8) < 1e-9 })      // 12 × 2/3
        #expect(Arrowhead.arms(tip: CGPoint(x: 5, y: 5), other: CGPoint(x: 5, y: 5), size: 4).isEmpty)
        #expect(Arrowhead.length(size: 40, lineLength: 1000) == 110)
    }

    @Test("矢じりの線：none は無し、end は終点の 2 本、both は両端の 4 本")
    func segmentsPerKind() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 100, y: 0)
        #expect(Arrowhead.segments(from: a, to: b, size: 4, arrow: .none).isEmpty)
        let end = Arrowhead.segments(from: a, to: b, size: 4, arrow: .end)
        #expect(end.count == 2 && end.allSatisfy { $0.tip == b })
        let both = Arrowhead.segments(from: a, to: b, size: 4, arrow: .both)
        #expect(both.count == 4 && both.filter { $0.tip == a }.count == 2 && both.filter { $0.tip == b }.count == 2)
    }

    @Test("bounds：矢じりの先まで含める（掴める範囲・動かせる範囲・書き出しの範囲）。線だけなら、これまでと同じ")
    func boundsIncludeTheHeads() {
        let plain = lineItem(CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)).bounds
        #expect(plain == CGRect(x: -2, y: 98, width: 104, height: 4))
        let arrow = lineItem(CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100), arrow: .end).bounds
        let reach = 20 * sin(28 * CGFloat.pi / 180)
        #expect(abs(arrow.minY - (100 - reach - 2)) < 1e-9 && abs(arrow.maxY - (100 + reach + 2)) < 1e-9)
        #expect(arrow.minX == -2 && arrow.maxX == 102)     // 矢じりは、線の内側へ向く
        let both = lineItem(CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100), arrow: .both).bounds
        #expect(both.height == arrow.height)
    }

    @Test("描画：矢じりのある直線は、矢じりの画素が塗られる。線だけなら塗られない")
    func rendersTheHead() throws {
        func png(_ arrow: Item.Arrow) throws -> NSBitmapImageRep {
            let data = try #require(CanvasRenderer.pngData(Document(items: [lineItem(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), arrow: arrow)]), size: CGSize(width: 480, height: 320), transparent: false))
            return try #require(NSBitmapImageRep(data: data))
        }
        func dark(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> Bool {   // 点の座標（書き出しは 2 倍）
            guard let c = rep.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent < 0.3
        }
        // 終点（300,100）から、左へ 28° 開いた腕の途中（長さ 20 の、半分）
        let mid = CGPoint(x: 300 - 10 * cos(28 * CGFloat.pi / 180), y: 100 + 10 * sin(28 * CGFloat.pi / 180))
        let mirrored = CGPoint(x: mid.x, y: 200 - mid.y)
        let none = try png(.none), end = try png(.end), both = try png(.both)
        #expect(!dark(none, mid.x, mid.y) && !dark(none, mirrored.x, mirrored.y))
        #expect(dark(end, mid.x, mid.y) && dark(end, mirrored.x, mirrored.y))
        // 始点の矢じり（右へ開く）は、両端のときだけ
        let startMid = CGPoint(x: 100 + 10 * cos(28 * CGFloat.pi / 180), y: 100 + 10 * sin(28 * CGFloat.pi / 180))
        #expect(!dark(end, startMid.x, startMid.y) && dark(both, startMid.x, startMid.y))
    }

    @Test("回しても、矢じりは、直線についてくる（直線の点を回す）。移動・端の取っ手・取り消しでも、矢じりの種類は保たれる")
    func arrowSurvivesRotationMoveAndResize() throws {
        let doc = Document().appending(lineItem(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), arrow: .both))
        let turned = try #require(doc.rotating(itemAt: 0, by: .pi / 2))
        #expect(turned.items[0].arrow == .both)
        guard case .line(let a, let b) = turned.items[0].content else { Issue.record("直線でない"); return }
        #expect(near(a, CGPoint(x: 200, y: 0), 1e-9) && near(b, CGPoint(x: 200, y: 200), 1e-9))
        let moved = try #require(doc.translatingItem(at: 0, by: CGSize(width: 10, height: 10), keepingGrabAreaIn: CGRect(x: 0, y: 0, width: 480, height: 320)))
        #expect(moved.items[0].arrow == .both)
        let resized = try #require(doc.applying(.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 150)), toItemAt: 0))
        #expect(resized.items[0].arrow == .both)
    }
}

@Suite("矢印：操作の JSON と get（A32）")
struct ArrowOpsTests {
    private func parse(_ ops: String) -> Result<[Op], AgentError> { OpsParser.parse(Data("{\"version\":1,\"ops\":[\(ops)]}".utf8)) }

    @Test("line の arrow は、\"none\"・\"end\"・\"both\" の文字列だけ。省くと none。ほかの op には無い")
    func parsesArrow() throws {
        let ops = try parse(##"{"op":"line","from":[0,0],"to":[50,50]},{"op":"line","from":[0,0],"to":[50,50],"arrow":"end"},{"op":"line","from":[0,0],"to":[50,50],"arrow":"both","color":"#ff0000"}"##).get()
        #expect(ops[0] == .line(from: .zero, to: CGPoint(x: 50, y: 50), color: .black, size: 4, arrow: .none))
        #expect(ops[1] == .line(from: .zero, to: CGPoint(x: 50, y: 50), color: .black, size: 4, arrow: .end))
        if case .line(_, _, _, _, let arrow) = ops[2] { #expect(arrow == .both) } else { Issue.record("直線でない") }
        for bad in ["\"start\"", "\"END\"", "true", "1", "null", "[\"end\"]", "\"\""] {
            if case .success = parse(#"{"op":"line","from":[0,0],"to":[50,50],"arrow":\#(bad)}"#) { Issue.record("arrow \(bad) が通った") }
        }
        if case .success = parse(#"{"op":"rect","x":1,"y":2,"w":30,"h":20,"arrow":"end"}"#) { Issue.record("rect に arrow が通った") }
        if case .success = parse(#"{"op":"pen","points":[[0,0]],"arrow":"end"}"#) { Issue.record("pen に arrow が通った") }
    }

    @Test("適用すると、要素の arrow になる。get の arrow が出て、読み直すと同じ操作に戻る。直線には、必ず arrow が出る")
    func appliesAndRoundTrips() throws {
        let ops = try parse(#"{"op":"line","from":[10,10],"to":[200,100],"arrow":"both"},{"op":"line","from":[10,20],"to":[200,120]}"#).get()
        let items = try OpsApply.items(from: ops, canvas: CGSize(width: 480, height: 320)).get().items
        #expect(items.map(\.arrow) == [.both, .none])
        let json = items.enumerated().map { ItemEncoder.json($1, index: $0) }
        #expect(json.map { $0["arrow"] as? String } == ["both", "none"])
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "ops": json.map { $0.filter { $0.key != "index" } }])
        let again = try OpsParser.parse(data).get()
        #expect(try OpsApply.items(from: again, canvas: CGSize(width: 480, height: 320)).get().items.map(\.arrow) == [.both, .none])
        #expect(ItemEncoder.json(Item(content: .rect(CGRect(x: 0, y: 0, width: 5, height: 5)), color: black, size: 4), index: 0)["arrow"] == nil)
    }
}

@Suite("矢印：キャンバスとツールバー（A32）")
@MainActor
struct ArrowUITests {
    private func allSubviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allSubviews) }

    private func mouse(_ type: NSEvent.EventType, _ canvas: CanvasView, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(_ c: CanvasView, from a: CGPoint, to b: CGPoint) throws {
        c.mouseDown(with: try mouse(.leftMouseDown, c, a))
        c.mouseDragged(with: try mouse(.leftMouseDragged, c, b))
        c.mouseUp(with: try mouse(.leftMouseUp, c, b))
    }

    @Test("直線のツールで、選んだ矢じりのとおりに、確定した直線が arrow になる。取り消せる。普通の直線は、線のまま")
    func canvasDrawsWithTheChoice() throws {
        let c = CanvasView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        c.tool = .line
        try drag(c, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90))
        c.lineArrow = .end
        try drag(c, from: CGPoint(x: 20, y: 120), to: CGPoint(x: 120, y: 190))
        c.lineArrow = .both
        try drag(c, from: CGPoint(x: 220, y: 120), to: CGPoint(x: 320, y: 190))
        #expect(c.document.items.map(\.arrow) == [.none, .end, .both])
        c.undo()
        #expect(c.document.items.map(\.arrow) == [.none, .end])
    }

    @Test("ツールバー：直線のボタンにメニュー（線／矢印／両端の矢印）。選ぶと、通知・チェック・ツールの切り替えが起きる。図形のメニューとは別")
    func toolbarMenu() throws {
        let toolbar = Toolbar()
        let control = try #require(allSubviews(toolbar.topRow).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 5 })
        let menu = try #require(control.menu(forSegment: Toolbar.segment(for: .line)))
        #expect(menu.items.map(\.title) == ["線", "矢印", "両端の矢印"])
        #expect(menu.items.map(\.state) == [.on, .off, .off])
        #expect(menu.items.allSatisfy { $0.image != nil })
        #expect(control.showsMenuIndicator(forSegment: Toolbar.segment(for: .line)))
        #expect(control.menu(forSegment: Toolbar.segment(for: .pen)) == nil)

        var arrows: [Item.Arrow] = [], tools: [Tool] = [], fills: [String] = []
        toolbar.onSelectArrow = { arrows.append($0) }
        toolbar.onSelectTool = { tools.append($0) }
        toolbar.onSelectFill = { fills.append("\($0)=\($1)") }
        control.selectedSegment = Toolbar.segment(for: .pen)

        menu.performActionForItem(at: 2)
        #expect(arrows == [.both] && tools == [.line] && control.selectedSegment == Toolbar.segment(for: .line) && fills.isEmpty)
        #expect(menu.items.map(\.state) == [.off, .off, .on])
        menu.performActionForItem(at: 1)
        #expect(arrows == [.both, .end] && menu.items.map(\.state) == [.off, .on, .off])
        menu.performActionForItem(at: 0)
        #expect(arrows.last == Item.Arrow.none && menu.items.map(\.state) == [.on, .off, .off])
    }
}

@Suite("矢印：ツールバーの幅（レビューの指摘）")
@MainActor
struct ArrowToolbarWidthTests {
    @Test("どの矢じりを選んでも、ボタンの幅・ツールバーの上段の幅は変わらない。ボタンの絵は、選びに合わせて変わる")
    func widthIsConstant() throws {
        let toolbar = Toolbar()
        let control = try #require((toolbar.topRow.subviews + toolbar.topRow.subviews.flatMap(\.subviews)).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 5 })
        let menu = try #require(control.menu(forSegment: Toolbar.segment(for: .line)))
        let widthBefore = control.intrinsicContentSize.width, rowBefore = toolbar.topRow.fittingSize.width
        let imageBefore = control.image(forSegment: Toolbar.segment(for: .line))?.tiffRepresentation
        menu.performActionForItem(at: 2)   // 両端の矢印（絵を作り直す）
        #expect(abs(control.intrinsicContentSize.width - widthBefore) <= 1)     // 以前は 2 pt 広がった（16×15 の絵）。半分の pt の丸めだけは許す
        #expect(toolbar.topRow.fittingSize.width == rowBefore)
        #expect(control.image(forSegment: Toolbar.segment(for: .line))?.tiffRepresentation != imageBefore)
        menu.performActionForItem(at: 1)
        #expect(abs(control.intrinsicContentSize.width - widthBefore) <= 1 && toolbar.topRow.fittingSize.width == rowBefore)
    }
}

@Suite("矢印：ボタンの絵の向き")
@MainActor
struct ArrowIconTests {
    /// 絵を、32×32 のビットマップに描いて、四分の一ごとの、インク（不透明度）の合計。
    private func ink(_ image: NSImage) throws -> (topLeft: Double, topRight: Double, bottomLeft: Double, bottomRight: Double) {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        var q = (topLeft: 0.0, topRight: 0.0, bottomLeft: 0.0, bottomRight: 0.0)
        for y in 0..<32 { for x in 0..<32 {   // y は、上から数える（ビットマップの行）
            let a = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            if y < 16 { if x < 16 { q.topLeft += a } else { q.topRight += a } } else { if x < 16 { q.bottomLeft += a } else { q.bottomRight += a } }
        } }
        return q
    }

    @Test("線の絵は、左下から右上へ（／）。矢印の絵は、右上に矢じり。両端の絵は、左下と右上の両方にインクがあり、左上・右下は、ほとんど無い（／の向き）")
    func orientation() throws {
        let line = try ink(try #require(Toolbar.arrowImage(.none)))
        #expect(line.topRight > line.topLeft && line.bottomLeft > line.bottomRight)
        let both = try ink(try #require(Toolbar.arrowImage(.both)))
        #expect(both.topRight > 2 * both.topLeft && both.bottomLeft > 2 * both.bottomRight, "\(both)")
        let single = try ink(try #require(Toolbar.arrowImage(.end)))
        #expect(both.bottomLeft > single.bottomLeft)    // 両端のほうが、左下にもインクがある（矢じりの分）
    }
}
