import AppKit

/// キャンバスのまわりに浮かぶパレット（SPEC §4）：上（ツール・画像追加・色・いまのツールに関係する大きさ）、
/// 下の左（ドラッグで渡す・パスをコピー）、下の右（背景透過・クリア）。
/// 操作は、コールバックで通知するだけ。何をするかは `PaintWindowController` が決める。
final class Toolbar: NSObject {
    /// ブラシの太さの範囲。
    static let brushRange: ClosedRange<CGFloat> = 1...40

    var onSelectTool: ((Tool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onBrushSize: ((CGFloat) -> Void)?
    var onTextSize: ((CGFloat) -> Void)?
    var onTransparent: ((Bool) -> Void)?
    var onPickImages: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onClear: (() -> Void)?
    /// 図形（円・四角・三角）の描き方（枠だけ／塗りつぶし）が選ばれた。選んだツールへの切り替えも、`onSelectTool` で別に知らせる。
    var onSelectFill: ((Tool, Bool) -> Void)?
    /// 直線の矢じり（線・矢印・両端の矢印）が選ばれた。直線のツールへの切り替えも、`onSelectTool` で別に知らせる。
    var onSelectArrow: ((Item.Arrow) -> Void)?
    /// 直線で選んでいる矢じり。ボタンの絵とメニューのチェックに使う。保存しない。
    private var lineArrow: Item.Arrow = .none
    /// 「図形」のボタンが、いま表す図形（円・四角・三角）。ボタンの絵とメニューの印に使う。保存しない。
    private var shapeTool: Tool = .ellipse
    /// 塗りつぶしを選んでいる図形。ボタンの絵とメニューの印に使う。保存しない。
    private var filledTools: Set<Tool> = []
    private let shapeMenuView = ShapeMenuView()
    var fileProvider: (() -> URL?)? {
        get { handle.fileProvider }
        set { handle.fileProvider = newValue }
    }

    private let topDivider = PaletteDivider()
    private let grip = PaletteGrip()

    /// 上のパレット（ドラッグで、置き場所を動かせる）。大きさの部品（ブラシ／文字サイズ）は、いまのツールに関係するものだけが出るので、横並びでは右へ、縦並びでは下へ伸び縮みする（ツールのボタンは動かない）。
    private(set) lazy var topPill = FloatingPill(arranged: [grip, toolStack, topDivider, pickButton, colorWell, slider, textSizePopup])

    /// 下のパレットの左：書き出した画像を渡す 2 つの方法。
    private(set) lazy var outputPill = FloatingPill(arranged: [handle, PaletteDivider(), copyButton])

    /// 下のパレットの右：背景透過とクリア。
    private(set) lazy var actionsPill = FloatingPill(arranged: [transparentButton, clearButton])

    private let handle = DragHandleView()
    private static let copyTitle = "パスをコピー"

    private lazy var copyButton: PaletteButton = {
        let button = PaletteButton(symbol: "doc.on.doc", label: Self.copyTitle, pointSize: 13, showsTitle: true, size: NSSize(width: 112, height: 30))
        button.target = self
        button.action = #selector(copyPath)
        return button
    }()

    /// 描いたものを消す。背景画像は残る。取り消しで戻せるので、確認は出さない。
    private lazy var clearButton: PaletteButton = {
        let button = PaletteButton(symbol: "trash", label: "クリア")
        button.target = self
        button.action = #selector(clearCanvas)
        return button
    }()

    private lazy var transparentButton: PaletteButton = {
        let button = PaletteButton(symbol: "checkerboard.rectangle", label: "背景透過", role: .checkbox)
        button.setButtonType(.pushOnPushOff)   // 押すたびに、入／切が替わる
        button.target = self
        button.action = #selector(transparentChanged(_:))
        return button
    }()

    /// ボタンの並び（左から）。円・四角・三角は、「図形」の 1 つにまとまる。
    private static let segmentOrder: [[Tool]] = [[.pen], [.line], ShapeMenuView.shapes, [.text], [.number], [.eraser], [.move], [.hand]]
    private static let toolSymbols = ["pencil.tip", "line.diagonal", "circle", "textformat", "1.circle.fill", "eraser", "arrow.up.and.down.and.arrow.left.and.right", "hand.raised"]
    private static let toolLabels = ["ペン", "直線", "図形", "文字", "番号", "消しゴム", "移動", "ハンド"]

    static func segment(for tool: Tool) -> Int {
        segmentOrder.firstIndex { $0.contains(tool) } ?? 0
    }

    /// ツールのボタン（左から。`segment(for:)` の順）。
    private(set) lazy var toolButtons: [PaletteButton] = Self.segmentOrder.indices.map { index in
        let button = PaletteButton(symbol: Self.toolSymbols[index], label: Self.toolLabels[index], role: .radio)
        button.target = self
        button.action = #selector(toolPressed(_:))
        button.tag = index
        return button
    }

    func button(for tool: Tool) -> PaletteButton { toolButtons[Self.segment(for: tool)] }

    private lazy var toolStack: NSStackView = {
        let stack = NSStackView(views: toolButtons)
        stack.orientation = .horizontal
        stack.spacing = 2
        return stack
    }()

    override init() {
        super.init()
        // 図形のボタンに、2 列 × 3 行のメニュー（押し続けると開く。目印が出る）。普通に押すと、ツールの選択だけ。
        button(for: .ellipse).menuProvider = { [weak self] in self?.shapeMenu() }
        button(for: .ellipse).setSymbolImage(Self.shapeImage(.ellipse, filled: false))   // 起動のときは、枠だけの円
        // 直線のボタンにも、「線／矢印／両端の矢印」のメニュー（同じ形）
        button(for: .line).menuProvider = { [weak self] in self?.arrowMenu() }
        button(for: .pen).isOn = true
        topPill.isDraggable = true
        topPill.onDrag = { [weak self] phase, point in self?.onPaletteDrag?(phase, point) }
        applyOrientation()
    }

    /// 上のパレットの置き場所と向き（SPEC §4）。入れると、並びと、大きさの部品の長さが替わる。ウィンドウの大きさは、`PaintWindowController` が合わせる。
    var orientation: PaletteOrientation = .top {
        didSet { if oldValue != orientation { applyOrientation() } }
    }

    /// パレットがドラッグされている（動かし始め・動かしている間・離した）。位置は、窓の内容の座標（下が 0）。置き場所を決めるのは、呼び出し側。
    var onPaletteDrag: ((FloatingPill.DragPhase, NSPoint) -> Void)?

    private func applyOrientation() {
        let vertical = orientation.isVertical
        let layout: NSUserInterfaceLayoutOrientation = vertical ? .vertical : .horizontal
        topPill.orientation = layout
        toolStack.orientation = layout
        toolStack.spacing = vertical ? 3 : 2   // 縦並びは、面を少し小さく（28 pt）して、隣のボタンの面との間をあける。最小のキャンバスの窓の高さに収めるため、ピッチは同じ（31 pt）
        for button in toolButtons { button.setSize(vertical ? NSSize(width: 28, height: 28) : NSSize(width: 30, height: 30)) }
        topPill.spacing = vertical ? 1 : 2
        topDivider.isVerticalLine = !vertical
        grip.isVertical = vertical
        sliderWidth.constant = vertical ? 52 : 76
        sliderWidth.isActive = true
        verticalPillWidth.isActive = vertical
        verticalPopupWidth.isActive = vertical
    }

    /// 上のパレットの、縁に沿った長さのうち、いちばん長い形（ブラシのスライダー、または文字サイズのポップアップが出ているとき）。
    /// 大きさの部品は、ツールによって出入りするので、いまの長さに、出ていない分（長いほうの部品）を足す。縁に沿った位置の余りを決めるのに使う。
    var longestPillLength: CGFloat {
        let vertical = orientation.isVertical
        let fitting = topPill.fittingSize
        let current = vertical ? fitting.height : fitting.width
        func extent(_ view: NSView) -> CGFloat { vertical ? view.fittingSize.height : (view === slider ? sliderWidth.constant : view.fittingSize.width) }
        let spacing = topPill.spacing
        let shown = (slider.isHidden ? 0 : extent(slider) + spacing) + (textSizePopup.isHidden ? 0 : extent(textSizePopup) + spacing)
        let longest = max(extent(slider), extent(textSizePopup)) + spacing
        return current - shown + longest
    }

    private lazy var colorWell: ColorSwatchButton = {
        let swatch = ColorSwatchButton()
        swatch.onChange = { [weak self] color in self?.onColor?(color) }
        return swatch
    }()

    private lazy var slider: NSSlider = {
        let slider = NSSlider(value: 4, minValue: Double(Self.brushRange.lowerBound), maxValue: Double(Self.brushRange.upperBound), target: self, action: #selector(sizeChanged(_:)))
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        return slider
    }()
    /// スライダーの長さ（横並びは 76、縦並びは、パレットの幅に収まる長さ）。縦並びでも、スライダーは横向き（縦向きにすると、高さが足りず、短くなりすぎる）。
    private lazy var sliderWidth = slider.widthAnchor.constraint(equalToConstant: 76)
    /// 縦並びのとき、パレットの幅を一定にする（文字サイズのポップアップが出入りしても、ツールのボタンとキャンバスが動かない）。
    private static let verticalPillWidthValue: CGFloat = 76
    private lazy var verticalPillWidth = topPill.widthAnchor.constraint(equalToConstant: Self.verticalPillWidthValue)
    private lazy var verticalPopupWidth = textSizePopup.widthAnchor.constraint(equalToConstant: 64)

    /// 文字を入れるときの大きさ（ブラシの太さとは別）。文字のツールのときだけ出る。
    private lazy var textSizePopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: TextSize.presets.map { "\(Int($0)) pt" })
        popup.selectItem(at: TextSize.presets.firstIndex(of: TextSize.default) ?? 0)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        popup.bezelStyle = .inline
        popup.target = self
        popup.action = #selector(textSizeChanged(_:))
        popup.refusesFirstResponder = true
        popup.setAccessibilityLabel("文字サイズ")
        popup.setAccessibilityIdentifier("text-size")
        popup.toolTip = "文字サイズ"
        popup.isHidden = true
        return popup
    }()

    private lazy var pickButton: PaletteButton = {
        let button = PaletteButton(symbol: "photo.badge.plus", label: "画像を追加")
        button.target = self
        button.action = #selector(pickImages)
        return button
    }()

    /// ブラシの太さを使うツール（ペン・直線・円・四角・三角）。移動・消しゴム・ハンドは、太さを使わない。文字は、文字サイズを使う。
    private static func usesBrush(_ tool: Tool) -> Bool {
        switch tool {
        case .pen, .line, .ellipse, .rect, .triangle: return true
        case .text, .number, .move, .hand, .eraser: return false
        }
    }

    /// 表示を、いまの状態に合わせる（キーボードで切り替えたときにも使う）。図形のツールなら、「図形」のボタンが、その図形になる。
    func show(tool: Tool) {
        if ShapeMenuView.shapes.contains(tool) {
            shapeTool = tool
            refreshShapeButton()
        }
        let selected = Self.segment(for: tool)
        for (index, button) in toolButtons.enumerated() { button.isOn = index == selected }
        slider.isHidden = !Self.usesBrush(tool)
        textSizePopup.isHidden = tool != .text
    }

    /// いま、ブラシの太さ・文字サイズの部品が出ているか（SPEC §4：いまのツールに関係するものだけ）。
    var showsBrushSize: Bool { !slider.isHidden }
    var showsTextSize: Bool { !textSizePopup.isHidden }

    // MARK: - 図形（円・四角・三角）と塗りつぶし

    /// ボタンの絵（SF Symbols）。ほかのツールと同じ大きさにそろえる。
    private static func shapeImage(_ tool: Tool, filled: Bool) -> NSImage? {
        NSImage(systemSymbolName: ShapeMenuView.symbol(for: tool, filled: filled), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    }

    private func shapeMenu() -> NSMenu {
        let menu = NSMenu(title: "図形")
        let item = NSMenuItem()
        shapeMenuView.onChoose = { [weak self] tool, filled in self?.shapeChosen(tool, filled: filled) }
        shapeMenuView.show(tool: shapeTool, filled: filledTools.contains(shapeTool))
        item.view = shapeMenuView
        menu.addItem(item)
        return menu
    }

    /// ボタンの絵と、メニューの印を、いまの選びに合わせる。
    private func refreshShapeButton() {
        let filled = filledTools.contains(shapeTool)
        button(for: shapeTool).setSymbolImage(Self.shapeImage(shapeTool, filled: filled))
        shapeMenuView.show(tool: shapeTool, filled: filled)
    }

    /// メニューから選んだ。図形と描き方を決め、ボタンの絵と印を直し、その図形のツールに切り替える。
    private func shapeChosen(_ tool: Tool, filled: Bool) {
        guard ShapeMenuView.shapes.contains(tool) else { return }
        shapeTool = tool
        if filled { filledTools.insert(tool) } else { filledTools.remove(tool) }
        show(tool: tool)
        onSelectFill?(tool, filled)
        onSelectTool?(tool)
    }

    // MARK: - 直線の矢じり

    /// メニューの項目：題と、矢じり。
    private static let arrowChoices: [(title: String, arrow: Item.Arrow)] = [("線", .none), ("矢印", .end), ("両端の矢印", .both)]

    /// 絵。線は `line.diagonal`、矢印は `line.diagonal.arrow`。両端の矢印は、矢印の絵を 180° 回して重ねたもの（同じ大きさ）。
    /// `pointSize` を渡すと、その大きさの絵になる（パレットのボタンは、ほかのツールと同じ 15）。
    static func arrowImage(_ arrow: Item.Arrow, pointSize: CGFloat? = nil) -> NSImage? {
        guard var line = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: nil),
              var single = NSImage(systemSymbolName: "line.diagonal.arrow", accessibilityDescription: nil) else { return nil }
        if let pointSize {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            line = line.withSymbolConfiguration(config) ?? line
            single = single.withSymbolConfiguration(config) ?? single
        }
        let arrowHead = single
        switch arrow {
        case .none: return line
        case .end: return arrowHead
        case .both:
            let both = NSImage(size: arrowHead.size, flipped: false) { rect in
                arrowHead.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: .pi)
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
                arrowHead.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                return true
            }
            both.isTemplate = true   // 色は、ボタン・メニューの色に合わせる
            return both
        }
    }

    private func arrowMenu() -> NSMenu {
        let menu = NSMenu(title: "直線")
        for (index, choice) in Self.arrowChoices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(arrowChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Self.arrowImage(choice.arrow)
            item.state = choice.arrow == lineArrow ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// メニューから選んだ。ボタンの絵を直し、直線のツールに切り替える。チェックは、開くたびに、いまの選びで作り直す。
    @objc private func arrowChosen(_ sender: NSMenuItem) {
        guard Self.arrowChoices.indices.contains(sender.tag) else { return }
        lineArrow = Self.arrowChoices[sender.tag].arrow
        button(for: .line).setSymbolImage(Self.arrowImage(lineArrow, pointSize: 15))
        show(tool: .line)
        onSelectArrow?(lineArrow)
        onSelectTool?(.line)
    }

    func show(brushSize: CGFloat) { slider.doubleValue = Double(brushSize) }
    func show(textSize: CGFloat) {
        if let index = TextSize.presets.firstIndex(of: textSize) { textSizePopup.selectItem(at: index) }
    }
    var color: NSColor {
        get { colorWell.color }
        set { colorWell.color = newValue }
    }

    /// ツールチップに、いまの割り当てを出す。
    func showHints(_ center: ShortcutCenter) {
        func hint(_ title: String, _ command: Command) -> String {
            let keys = center.chords(for: command).map(\.displayString).joined(separator: " / ")
            return keys.isEmpty ? title : "\(title)（\(keys)）"
        }
        button(for: .pen).toolTip = hint("ペン", .toolPen)
        button(for: .line).toolTip = hint("直線", .toolLine) + "　押し続けると、線／矢印／両端の矢印を選べる"
        let shapeKeys = [("円", Command.toolEllipse), ("四角", .toolRect), ("三角", .toolTriangle)]
            .map { entry -> String in
                let keys = center.chords(for: entry.1).map(\.displayString).joined(separator: " / ")
                return keys.isEmpty ? entry.0 : "\(entry.0) \(keys)"
            }.joined(separator: "・")
        button(for: .ellipse).toolTip = "図形（\(shapeKeys)）　押し続けると、図形と、枠だけ／塗りつぶしを選べる"
        button(for: .text).toolTip = hint("文字", .toolText)
        button(for: .number).toolTip = hint("番号（クリックで、1・2・3…の印を置く）", .toolNumber)
        button(for: .move).toolTip = hint("移動", .toolMove)
        button(for: .eraser).toolTip = hint("消しゴム（なぞった要素を、離すと消す）", .toolEraser)
        button(for: .hand).toolTip = hint("ハンド（ドラッグで、見えている範囲を動かす。ピンチ・Cmd+スクロールで拡大縮小）", .toolHand)
        pickButton.toolTip = hint("画像を追加…", .openImage)
        copyButton.toolTip = hint("書き出した画像のパスをコピー", .copyPath)
        clearButton.toolTip = hint("描いたものをすべて消す（背景画像は残る。取り消しで戻せる）", .clearCanvas)
        transparentButton.toolTip = "背景透過（書き出す画像の背景を、透明にする）"
        let smaller = center.chords(for: .brushSmaller).first?.displayString
        let larger = center.chords(for: .brushLarger).first?.displayString
        slider.toolTip = (smaller != nil && larger != nil) ? "ブラシサイズ（\(smaller!) 小さく / \(larger!) 大きく）" : "ブラシサイズ"
    }

    /// 「コピーしました」を一瞬だけ見せる。
    func flashCopied() {
        copyButton.setLabel("コピーしました")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.setLabel(Self.copyTitle)
        }
    }

    @objc private func toolPressed(_ sender: PaletteButton) {
        guard Self.segmentOrder.indices.contains(sender.tag) else { return }
        let tool = Self.segmentOrder[sender.tag].first ?? .pen
        let chosen = ShapeMenuView.shapes.contains(tool) ? shapeTool : tool   // 図形のボタンは、いま表す図形のツール
        show(tool: chosen)
        onSelectTool?(chosen)
    }
    @objc private func sizeChanged(_ sender: NSSlider) { onBrushSize?(CGFloat(sender.doubleValue)) }
    @objc private func textSizeChanged(_ sender: NSPopUpButton) {
        guard TextSize.presets.indices.contains(sender.indexOfSelectedItem) else { return }
        onTextSize?(TextSize.presets[sender.indexOfSelectedItem])
    }
    @objc private func transparentChanged(_ sender: NSButton) { onTransparent?(sender.state == .on) }
    @objc private func pickImages() { onPickImages?() }
    @objc private func copyPath() { onCopyPath?() }
    @objc private func clearCanvas() { onClear?() }
}
