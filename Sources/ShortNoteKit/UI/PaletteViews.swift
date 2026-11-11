import AppKit

/// キャンバスのまわりに浮かぶ、角丸・半透明の面（SPEC §4）。中の部品を、横に並べる。画面だけの部品で、書き出しには入らない。
final class FloatingPill: NSView {
    static let cornerRadius: CGFloat = 13
    private let effect = PillEffectView()
    private let stack: NSStackView

    init(arranged views: [NSView], spacing: CGFloat = 2, padding: CGFloat = 5) {
        stack = NSStackView(views: views)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        layer?.zPosition = 2   // ドラッグでキャンバスの上を通るとき、キャンバスの下に隠れないように

        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active   // パネルは、非アクティブ型。アクティブでないときも、同じ見た目にする
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    /// 縁と影の色は、見た目（ライト・ダーク）が変わったときにも、作り直す。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// 中の部品を並べる向き。横並び（既定）か、縦並び。
    var orientation: NSUserInterfaceLayoutOrientation {
        get { stack.orientation }
        set {
            stack.orientation = newValue
            stack.alignment = newValue == .horizontal ? .centerY : .centerX
        }
    }

    /// 中の部品の間のすきま。
    var spacing: CGFloat {
        get { stack.spacing }
        set { stack.spacing = newValue }
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            effect.layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowColor = NSColor.black.cgColor
        }
    }

    // MARK: - ドラッグ（置き場所を替える。SPEC §4）

    enum DragPhase { case began, moved, ended }

    /// ドラッグで動かせるか。動かせるパレットは、ポインタを押して動かすと、パレットがポインタについてくる（`onDrag` で知らせる。位置は、窓の内容の座標〔下が 0〕）。
    /// 動かせないパレットは、押して動かすと、窓が動く（ふつうの窓の動かし方）。
    var isDraggable = false { didSet { effect.movesWindow = !isDraggable } }
    var onDrag: ((DragPhase, NSPoint) -> Void)?
    private var dragStart = NSPoint.zero
    private var dragging = false
    /// 動かし始めとみなす距離（pt）。
    static let dragThreshold: CGFloat = 4

    override var mouseDownCanMoveWindow: Bool { !isDraggable }

    private func pointer(_ event: NSEvent) -> NSPoint { (superview ?? self).convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        guard isDraggable else { return super.mouseDown(with: event) }
        dragStart = pointer(event)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggable else { return super.mouseDragged(with: event) }
        let p = pointer(event)
        // 動かし始めるまでは、何もしない（押しただけ・少し動いただけで、置き場所が変わらないように）
        if !dragging {
            guard hypot(p.x - dragStart.x, p.y - dragStart.y) > Self.dragThreshold else { return }
            dragging = true
            onDrag?(.began, dragStart)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setAffineTransform(CGAffineTransform(translationX: p.x - dragStart.x, y: p.y - dragStart.y))
        CATransaction.commit()
        onDrag?(.moved, p)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggable else { return super.mouseUp(with: event) }
        guard dragging else { return }
        dragging = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setAffineTransform(.identity)
        CATransaction.commit()
        onDrag?(.ended, pointer(event))
    }
}

/// 効果ビュー（半透明の面）。窓を動かす操作に使うか（動かせないパレットは、使う）を決められる。
private final class PillEffectView: NSVisualEffectView {
    var movesWindow = true
    override var mouseDownCanMoveWindow: Bool { movesWindow }
}

/// パレットを動かすための、つまみ（点の並び）。押して動かすと、パレットのドラッグになる（イベントは、そのまま、パレットへ渡る）。
final class PaletteGrip: NSView {
    /// パレットが縦並びか（つまみは、パレットの上端の、横長になる）。
    var isVertical = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var intrinsicContentSize: NSSize { isVertical ? NSSize(width: 30, height: 26) : NSSize(width: 14, height: 30) }   // 縦並びは、すぐ下のツールのボタンと押し間違えないよう、高さをとる（縦のパレットの高さは、最小のキャンバスの窓の予算〔320 + 48 pt〕に収める。単体テストが見る）
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "ドラッグして、パレットを、キャンバスの上・左・右へ動かす"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("パレットを動かす")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        let dot: CGFloat = 2.5, gap: CGFloat = 3.5
        let columns = isVertical ? 3 : 2, rows = isVertical ? 2 : 3
        let width = CGFloat(columns) * dot + CGFloat(columns - 1) * gap, height = CGFloat(rows) * dot + CGFloat(rows - 1) * gap
        let origin = NSPoint(x: bounds.midX - width / 2, y: bounds.midY - height / 2)
        for column in 0..<columns {
            for row in 0..<rows {
                NSBezierPath(ovalIn: NSRect(x: origin.x + CGFloat(column) * (dot + gap), y: origin.y + CGFloat(row) * (dot + gap), width: dot, height: dot)).fill()
            }
        }
    }
}

/// パレットの細い仕切り。
final class PaletteDivider: NSView {
    /// 仕切りの線が縦（横並びのパレットの中）か、横（縦並びのパレットの中）か。
    var isVerticalLine = true { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize { isVerticalLine ? NSSize(width: 1, height: 18) : NSSize(width: 18, height: 1) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// パレットのボタン：枠のない、角丸の面。選んでいるとき（`isOn`）は淡いアクセント、ポインタが乗ると淡い色。
/// アイコンだけのボタンは、`label` が、ツールチップとアクセシビリティの名前になる（文字つきのボタンは、`setLabel` で文字を替えられる）。
/// `menuProvider` があるボタンは、押し続けると（`holdDelay` 秒）、そのメニューを開く（普通に押すと、ふつうの操作。右下に小さな目印が出る）。
class PaletteButton: NSButton {
    enum Role { case button, radio, checkbox }

    /// メニューを開くまでの、押し続ける時間（秒）。
    static let holdDelay: TimeInterval = 0.3

    private let role: Role
    private let showsTitle: Bool
    private var preferredSize: NSSize
    /// 押し続けたときに開くメニュー。無ければ、ふつうのボタン。
    var menuProvider: (() -> NSMenu?)? { didSet { needsDisplay = true } }
    private var hovering = false { didSet { if oldValue != hovering { refresh() } } }
    /// 押している間（自分で追跡する、ふつうの操作ボタン）。
    private var pressing = false { didSet { if oldValue != pressing { refresh() } } }

    /// 選んでいる（`state` が on）。標準のボタンは、押す・アクセシビリティの「押す」のたびに、`state` を入れ替えてしまうので、ふつうの操作ボタンは、セル（`PaletteButtonCell`）で、入れ替えを止めている。
    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }

    override var state: NSControl.StateValue {
        didSet { if oldValue != state { refresh() } }
    }

    override class var cellClass: AnyClass? {
        get { PaletteButtonCell.self }
        set {}
    }

    init(symbol: String?, label: String, role: Role = .button, pointSize: CGFloat = 15, showsTitle: Bool = false, size: NSSize = NSSize(width: 30, height: 30)) {
        self.role = role
        self.showsTitle = showsTitle
        self.preferredSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        }
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        toolTip = label
        setLabel(label)
        imagePosition = showsTitle ? .imageLeading : .imageOnly   // 枠と文字の設定のあとに決める（絵だけのボタンに、文字が出ないように）
        (cell as? PaletteButtonCell)?.keepsState = role == .button
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { preferredSize }

    /// ボタンの大きさを替える（縦並びでは、面を少し小さくして、隣との間をあける）。
    func setSize(_ size: NSSize) {
        guard size != preferredSize else { return }
        preferredSize = size
        invalidateIntrinsicContentSize()
    }

    /// ポインタが乗っている表示を消す。メニューの中のマスは、再利用するので、メニューが閉じたときに「離れた」を受け取れず、乗ったままの表示が残りうる。
    func clearHover() { hovering = false }

    /// 名前（文字つきのボタンでは、見える文字）を替える。
    func setLabel(_ text: String) {
        title = text
        setAccessibilityLabel(text)
        setAccessibilityTitle(text)
        refreshTitle()
    }

    /// ボタンの絵を替える（図形のボタンが、いま表す図形になる）。
    func setSymbolImage(_ newImage: NSImage?) {
        image = newImage
        needsDisplay = true
    }

    // MARK: - 見た目

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }   // 自分の領域だけ（ツールチップの領域〔`NSToolTipManager`〕を消さない）
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isOn {
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                contentTintColor = .controlAccentColor
            } else {
                layer?.backgroundColor = pressing ? NSColor.labelColor.withAlphaComponent(0.16).cgColor
                    : hovering ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
                contentTintColor = NSColor.labelColor.withAlphaComponent(0.82)
            }
        }
        refreshTitle()
    }

    /// 文字つきのボタンの、文字と絵は、標準のセルに任せず、描くときに、いまの外観で、自分で描く（標準のセルは、状態によって、文字の色を替え、
    /// 作ったときの外観で色が決まることがある。ダークの外観で、暗い文字が出ないように、色は、描く時点で決める）。
    private func refreshTitle() {
        guard showsTitle else { return }
        needsDisplay = true
    }

    private func drawTitled() {
        let textColor = NSColor.labelColor.withAlphaComponent(isOn ? 1 : 0.82)
        let tint = isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.82)
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: textColor])
        let textSize = text.size()
        var symbol: NSImage?
        if let image {
            let color = NSColor(cgColor: tint.cgColor) ?? tint   // 描いている時点の外観で、色を決める
            symbol = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        let gap: CGFloat = symbol == nil ? 0 : 5
        let symbolWidth = symbol?.size.width ?? 0
        var x = (bounds.midX - (symbolWidth + gap + textSize.width) / 2).rounded()
        if let symbol {
            symbol.draw(in: NSRect(x: x, y: (bounds.midY - symbol.size.height / 2).rounded(), width: symbol.size.width, height: symbol.size.height))
            x += symbolWidth + gap
        }
        text.draw(at: NSPoint(x: x, y: (bounds.midY - textSize.height / 2).rounded()))
    }

    /// メニューのあるボタンの、右下の小さな目印。
    override func draw(_ dirtyRect: NSRect) {
        if showsTitle { drawTitled() } else { super.draw(dirtyRect) }
        guard menuProvider != nil else { return }
        let tip = NSBezierPath()
        let x = bounds.maxX - 6, y = bounds.minY + 5
        tip.move(to: NSPoint(x: x - 3, y: y + 3))
        tip.line(to: NSPoint(x: x + 3, y: y + 3))
        tip.line(to: NSPoint(x: x, y: y))
        tip.close()
        (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.55)).setFill()
        tip.fill()
    }

    // MARK: - 押す・押し続ける

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard menuProvider != nil else {
            // ふつうの操作ボタン（パスをコピー・クリアなど）は、自分で、離すまで追跡する。押している間は、控えめな面（`pressing`）だけにする
            // （標準の追跡のあとに、選びのアクセントの面が残る不具合は、セル〔`PaletteButtonCell`〕で防ぐ。ここは、押している間の見た目のため）。
            if role == .button, let window { trackPress(in: window) } else { super.mouseDown(with: event) }
            return
        }
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        // 押し続けているか待つ。離したのが先なら、ふつうの操作。時間がきたら、メニューを開く。
        let deadline = Date(timeIntervalSinceNow: Self.holdDelay)
        if let up = window.nextEvent(matching: [.leftMouseUp], until: deadline, inMode: .eventTracking, dequeue: true) {
            if bounds.contains(convert(up.locationInWindow, from: nil)) { sendAction(action, to: target) }
        } else {
            showMenu()
        }
    }

    /// 離すまで追跡し、ボタンの上で離したときだけ、操作を送る。離すまで、押している面（`pressing`）を出す。
    private func trackPress(in window: NSWindow) {
        pressing = true
        var inside = true
        while let event = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            inside = bounds.contains(convert(event.locationInWindow, from: nil))
            pressing = inside
            if event.type == .leftMouseUp { break }
        }
        pressing = false
        if inside { sendAction(action, to: target) }
    }

    /// メニューを、ボタンの下に開く。押している間にここへ来たときは、そのまま、離した所のマスを選べる。
    @discardableResult
    func showMenu() -> Bool {
        guard let menu = menuProvider?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
        return true
    }

    // MARK: - アクセシビリティ

    override func accessibilityRole() -> NSAccessibility.Role? {
        switch role {
        case .button: return .button
        case .radio: return .radioButton
        case .checkbox: return .checkBox
        }
    }

    override func accessibilityValue() -> Any? {
        role == .button ? nil : NSNumber(value: isOn ? 1 : 0)
    }

    override func accessibilityPerformShowMenu() -> Bool { showMenu() }
}

/// 色の見本（丸）。押す（または押し続ける）と、代表的な色のマスと「その他の色…」のメニュー（`ColorMenuView`）が出る。選んだ色は、すぐ `onChange` で届く。
/// 「その他の色…」は、色のパネル（`NSColorPanel`）を開く（動かしている間も、すぐ届く）。
final class ColorSwatchButton: PaletteButton {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var onChange: ((NSColor) -> Void)?

    private let menuView = ColorMenuView()

    init() {
        super.init(symbol: nil, label: "色")
        target = self
        action = #selector(openMenu)
        menuProvider = { [weak self] in self?.makeMenu() }
        menuView.onChoose = { [weak self] color in self?.choose(color) }
        menuView.onOther = { [weak self] in self?.openPanel() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let disc = bounds.insetBy(dx: 5, dy: 5)
        color.setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()   // 白や黒に近い色でも、縁が見える
        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    @objc private func openMenu() { showMenu() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "色")
        let item = NSMenuItem()
        menuView.show(color: color)
        item.view = menuView
        menu.addItem(item)
        return menu
    }

    private func choose(_ new: NSColor) {
        color = new
        onChange?(new)
    }

    /// 色のパネルを開く（メニューが閉じてから）。動かしている間も、すぐ `onChange` で届く。
    private func openPanel() {
        DispatchQueue.main.async { [self] in
            let panel = NSColorPanel.shared
            panel.color = color
            panel.isContinuous = true
            panel.setTarget(self)
            panel.setAction(#selector(panelChanged(_:)))
            panel.orderFront(nil)
        }
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        color = sender.color
        onChange?(sender.color)
    }
}

/// パレットをドラッグしている間の、くっつく先の目印（その縁に出る、淡いアクセント色の帯）。クリックは受けない。
final class DropHintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        }
    }
}

/// `PaletteButton` のセル。標準の（瞬間の）ボタンは、押す・アクセシビリティの「押す」のたびに、`state` を、セルが直接、入れ替える（`state` の `didSet` も通らない）。
/// ふつうの操作ボタン（パスをコピー・クリアなど）は、押しても「選び」にならないので、次の状態を、いまの状態のままにする
/// （入れ替わると、押したあと、選びのアクセントの面が残る）。選びは、`isOn` で、明示的に決める（ツール・メニューの印）。
final class PaletteButtonCell: NSButtonCell {
    var keepsState = false

    override var nextState: Int { keepsState ? state.rawValue : super.nextState }
}
