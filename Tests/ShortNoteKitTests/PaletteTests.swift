import AppKit
import Testing
@testable import ShortNoteKit

@Suite("パレット（SPEC §4）")
@MainActor
struct PaletteTests {
    @Test("いまのツールに関係する大きさの部品だけが出る：ブラシはペン・直線・図形、文字サイズは文字、番号・移動・消しゴム・ハンドは、どちらも出ない")
    func sizeControlsFollowTheTool() {
        let toolbar = Toolbar()
        #expect(toolbar.showsBrushSize && !toolbar.showsTextSize)   // 起動のときは、ペン
        let expected: [Tool: (brush: Bool, text: Bool)] = [
            .pen: (true, false), .line: (true, false), .ellipse: (true, false), .rect: (true, false), .triangle: (true, false),
            .text: (false, true), .number: (false, false), .move: (false, false), .hand: (false, false), .eraser: (false, false),
        ]
        for tool in Tool.allCases {
            toolbar.show(tool: tool)
            #expect(toolbar.showsBrushSize == expected[tool]?.brush && toolbar.showsTextSize == expected[tool]?.text, "\(tool)")
        }
    }

    @Test("ツールのボタンは、どのツールでも、選んでいるものが 1 つだけ（図形のツールは、「図形」のボタン）。押すと、そのツールの通知が出て、選びが移る")
    func exactlyOneToolIsSelected() {
        let toolbar = Toolbar()
        for tool in Tool.allCases {
            toolbar.show(tool: tool)
            #expect(toolbar.toolButtons.filter(\.isOn).count == 1 && toolbar.button(for: tool).isOn, "\(tool)")
        }
        var chosen: [Tool] = []
        toolbar.onSelectTool = { chosen.append($0) }
        toolbar.button(for: .eraser).performClick(nil)
        toolbar.button(for: .text).performClick(nil)
        #expect(chosen == [.eraser, .text])
        #expect(toolbar.toolButtons.filter(\.isOn).count == 1 && toolbar.button(for: .text).isOn)
        #expect(toolbar.showsTextSize && !toolbar.showsBrushSize)
    }

    @Test("背景透過は、押すたびに入／切が替わり、そのたびに通知が出る")
    func transparencyToggles() throws {
        let toolbar = Toolbar()
        var values: [Bool] = []
        toolbar.onTransparent = { values.append($0) }
        let toggle = try #require(toolbar.actionsPill.allSubviews.compactMap { $0 as? PaletteButton }.first { $0.accessibilityTitle() == "背景透過" })
        toggle.performClick(nil)
        toggle.performClick(nil)
        #expect(values == [true, false])
    }
}

@Suite("パレットのドラッグ：押しただけでは動かない")
@MainActor
struct PaletteDragThresholdTests {
    private func event(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("押して、ほとんど動かさずに離しても、通知は出ない。しきい値を超えて動かすと、動かし始め・動いている・離した、の順に出る")
    func thresholdBeforeDragging() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let pill = FloatingPill(arranged: [NSView()])
        pill.isDraggable = true
        container.addSubview(pill)
        var phases: [FloatingPill.DragPhase] = []
        pill.onDrag = { phase, _ in phases.append(phase) }

        pill.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        pill.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 22, y: 21)))
        pill.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 22, y: 21)))
        #expect(phases.isEmpty)

        pill.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        pill.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 60, y: 50)))
        pill.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 80, y: 60)))
        pill.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 80, y: 60)))
        #expect(phases == [.began, .moved, .moved, .ended])
    }
}

@Suite("パレットの置き場所（ドラッグ。SPEC §4・§11）")
struct PaletteDockTests {
    private let window = CGSize(width: 504, height: 460)

    @Test("離した所に、いちばん近い縁（上・左・右）に、くっつく。下の縁は、置き場所ではない")
    func nearestEdge() {
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 250, y: 10), in: window, current: .left) == .top)
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 20, y: 250), in: window, current: .top) == .left)
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 490, y: 250), in: window, current: .top) == .right)
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 250, y: 440), in: window, current: .left) != .top)   // 下の端近くでも、上には戻らない：左・右の近いほう
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 100, y: 100), in: window, current: .right) == .top)   // 上と左が同じくらいなら、上を先に
    }

    @Test("いまの置き場所は、近いものとして数える：左のパレットのつまみ（窓の上端の近く）を持っただけでは、上に変わらない。上のほうへ、はっきり動かすと変わる")
    func currentEdgeSticks() {
        // 左に付いたパレットのつまみ：左の縁から 30、上の縁から 15
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 30, y: 15), in: window, current: .left) == .left)
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 30, y: 15), in: window, current: .top) == .top)   // 上のパレットなら、上のまま
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 200, y: 15), in: window, current: .left) == .top)   // 上へ、はっきり動かした
        #expect(PaletteDock.orientation(forPointer: CGPoint(x: 470, y: 150), in: window, current: .left) == .right)   // 右へ、はっきり動かした
    }

    @Test("縁に沿った位置：パレットを持った所が、離した位置に来る。縁の内側に収まる（端の外へ出ない）")
    func offsetClampsToTheEdge() {
        // 長さ 400 のパレットを、使える長さ 480（始まりは 12）の縁に置く。持った所は、始まりから 10
        #expect(PaletteDock.offset(pointerAlongEdge: 12 + 10, grab: 10, palette: 400, start: 12, track: 480) == 0)
        #expect(PaletteDock.offset(pointerAlongEdge: 12 + 10 + 37, grab: 10, palette: 400, start: 12, track: 480) == 37)   // 動かした分だけ、ぴったり動く（1 pt 単位）
        #expect(PaletteDock.offset(pointerAlongEdge: 600, grab: 10, palette: 400, start: 12, track: 480) == 80)   // 縁の外へは出ない（余りは 80）
        #expect(PaletteDock.offset(pointerAlongEdge: -50, grab: 10, palette: 400, start: 12, track: 480) == 0)
        #expect(PaletteDock.offset(pointerAlongEdge: 300, grab: 10, palette: 500, start: 12, track: 480) == 0)    // パレットのほうが長いときは、動かさない
    }

    @Test("縦並び（左・右）でも、どのツールでも、パレットの幅は一定で、高さは最小のキャンバスの窓に収まる")
    @MainActor
    func verticalPaletteFits() {
        let toolbar = Toolbar()
        for orientation in [PaletteOrientation.left, .right] {
            toolbar.orientation = orientation
            var widths = Set<CGFloat>()
            for tool in Tool.allCases {
                toolbar.show(tool: tool)
                let size = toolbar.topPill.fittingSize
                widths.insert(size.width)
                // 最小のキャンバスの高さに、下のパレットの 1 行分（40 pt と余白 8 pt）を足した中に収める（窓の最小の高さを、押し上げない。
                // 押し上げると、置き場所を替えたとき、最小のキャンバスが大きくなってしまう）
                #expect(size.height <= CanvasView.minimumSize.height + 48, "\(orientation)・\(tool) で、縦のパレットが高すぎる：\(size.height)")
            }
            #expect(widths.count == 1, "\(orientation) で、ツールによって、縦のパレットの幅が変わった：\(widths)")
        }
    }

    @Test("パレットの、いちばん長い形の長さは、どのツールを選んでいても同じで、どのツールのときの長さより短くない（縁に沿った余りを、ツールによらず決めるため）")
    @MainActor
    func longestLengthIsToolIndependent() {
        let toolbar = Toolbar()
        for orientation in PaletteOrientation.allCases {
            toolbar.orientation = orientation
            var longest = Set<Int>()
            var actual: CGFloat = 0
            for tool in Tool.allCases {
                toolbar.show(tool: tool)
                let size = toolbar.topPill.fittingSize
                actual = max(actual, orientation.isVertical ? size.height : size.width)
                longest.insert(Int(toolbar.longestPillLength.rounded()))
            }
            #expect(longest.count == 1, "\(orientation)：ツールによって、いちばん長い形の長さが変わった：\(longest)")
            #expect(CGFloat(longest.first ?? 0) >= actual - 1, "\(orientation)：いちばん長い形（\(longest)）が、実際の最大（\(actual)）より短い")
        }
    }

    @Test("パレットは、つまみから動かせる（`isDraggable`）。ほかのパレットは、窓を動かす")
    @MainActor
    func onlyThePaletteDrags() {
        let toolbar = Toolbar()
        #expect(toolbar.topPill.isDraggable && !toolbar.outputPill.isDraggable && !toolbar.actionsPill.isDraggable)
    }

    @Test("置き場所と縁に沿った位置を保存して、読み戻す。無い・読めない値は、上・0")
    func storeRoundTripAndFallback() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShortNoteTests.paletteOrientation.\(UUID().uuidString)"))
        let store = PaletteOrientationStore(defaults: defaults)
        #expect(store.load() == .top && store.loadOffset() == 0)
        store.save(.right, offset: 37)
        #expect(store.load() == .right && store.loadOffset() == 37)
        defaults.set("diagonal", forKey: PaletteOrientationStore.key)
        defaults.set(-5.0, forKey: PaletteOrientationStore.offsetKey)
        #expect(store.load() == .top && store.loadOffset() == 0)
        defaults.set(Double.nan, forKey: PaletteOrientationStore.offsetKey)
        #expect(store.loadOffset() == 0)
    }
}

private extension NSView {
    var allSubviews: [NSView] { subviews + subviews.flatMap(\.allSubviews) }
}
