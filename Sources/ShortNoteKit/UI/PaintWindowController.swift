import AppKit

/// パネル（ツールバー＋キャンバス）の組み立てと、コマンドの実行。
/// ツールバーの操作もショートカットも、同じ `perform(_:)` を通る。
final class PaintWindowController: NSObject {
    private let panel: PaintPanel
    private let canvas = CanvasView(frame: NSRect(origin: .zero, size: CanvasView.minimumSize))
    private let viewControls = ViewControlsView(frame: .zero)
    private let toolbar = Toolbar()
    private let exportStore = ExportStore()
    private let sizeStore = CanvasSizeStore()
    private let center: ShortcutCenter
    private lazy var sizing = CanvasSizing(panel: panel, canvas: canvas)
    private var positioned = false
    private let root = NSView()
    private let orientationStore = PaletteOrientationStore()
    /// ツールのパレットの置き場所ごとの配置（どれか 1 つだけが有効）と、縁に沿った位置の制約（定数は、`base` ＋ 位置）。
    private var layouts: [PaletteOrientation: [NSLayoutConstraint]] = [:]
    private var offsetConstraints: [PaletteOrientation: (constraint: NSLayoutConstraint, base: CGFloat)] = [:]
    private var orientation: PaletteOrientation = .top
    private let dropHint = DropHintView()
    /// ドラッグで、パレットを持った所（パレットの始まりからの距離）と、ドラッグを始めたときの置き場所。
    private var grab: CGFloat = 0
    private var dragStartOrientation: PaletteOrientation = .top
    /// 別の縁へ移すときに、持った所として数える、始まりからの最大の距離（つまみの近く）。
    private static let maxGrab: CGFloat = 30
    /// 窓の左右の余白。
    private static let side: CGFloat = 12

    /// ブラシを `brushSmaller`／`brushLarger` で動かす 1 回あたりの幅。
    private static let brushStep: CGFloat = 2

    init(center: ShortcutCenter) {
        self.center = center
        panel = PaintPanel(
            contentRect: NSRect(origin: .zero, size: CanvasView.minimumSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildUI()
        // 保存したサイズが、いまの画面に収まらないとき（外付けディスプレイを外したなど）は、収まる最大まで縮めて起動する。保存した値は変えない。
        // 画像つきで起動したときも、画像の配置がこの大きさのキャンバスで決まるように、ここで適用する。
        sizing.apply(CanvasSize.fitting(sizeStore.load(), in: sizing.limits))
        toolbar.showHints(center)
    }

    // MARK: - 組み立て

    private func buildUI() {
        panel.title = "ShortNote"
        panel.titleVisibility = .hidden   // 名前は、タイトルバーに出さない（`title` は、そのまま持つ）
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .underPageBackgroundColor   // キャンバスのまわりの余白は、ビューの外側（§3.2.5）と同じ、暗い色
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        canvas.onChange = { [weak self] in self?.exportStore.invalidate() }
        canvas.onIntakeFailure = { _ in NSSound.beep() }
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            canvas.setContentHuggingPriority(.defaultLow, for: axis)
            canvas.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: CanvasView.minimumSize.width).isActive = true
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: CanvasView.minimumSize.height).isActive = true

        toolbar.color = canvas.color
        toolbar.show(brushSize: canvas.brushSize)
        toolbar.show(textSize: canvas.textSize)
        toolbar.onSelectTool = { [weak self] tool in self?.canvas.tool = tool }
        toolbar.onSelectFill = { [weak self] tool, filled in
            switch tool {
            case .ellipse: self?.canvas.fillEllipse = filled
            case .rect: self?.canvas.fillRect = filled
            case .triangle: self?.canvas.fillTriangle = filled
            default: break
            }
        }
        toolbar.onSelectArrow = { [weak self] arrow in self?.canvas.lineArrow = arrow }
        toolbar.onColor = { [weak self] color in self?.canvas.color = color }
        toolbar.onBrushSize = { [weak self] size in self?.canvas.brushSize = size }
        toolbar.onTextSize = { [weak self] size in self?.canvas.textSize = size }
        toolbar.onTransparent = { [weak self] on in self?.canvas.transparent = on }
        toolbar.onPickImages = { [weak self] in self?.pickImages() }   // ボタンは入力中でも効く（入力を確定してから開く）。キーの openImage は、入力中は無視する
        toolbar.onCopyPath = { [weak self] in self?.perform(.copyPath) }
        toolbar.onClear = { [weak self] in self?.perform(.clearCanvas) }
        toolbar.fileProvider = { [weak self] in self?.exportFile() }

        // 窓の背景（暗い色）に、パレットが浮かぶ：ツールのパレット、キャンバス、下の 2 つのパレット。キャンバスの上には重ねない（SPEC §4）。
        // ツールのパレットは、キャンバスの上（横並び）・左（縦並び）・右（縦並び）。ドラッグで動かせる。3 つの配置を作っておき、置き場所に合う 1 つだけを有効にする。
        let top = toolbar.topPill, output = toolbar.outputPill, actions = toolbar.actionsPill
        for v in [top, canvas, output, actions] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let side = Self.side, gap: CGFloat = 8
        NSLayoutConstraint.activate([
            output.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: gap),
            output.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -side),
            actions.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: gap),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: output.trailingAnchor, constant: gap),
        ])
        /// 縁に沿った位置の制約：窓が狭いときは、縮められる（優先度を下げる）。縁の内側に収める制約は、別に、必須で置く。
        func along(_ constraint: NSLayoutConstraint, base: CGFloat, _ orientation: PaletteOrientation) -> NSLayoutConstraint {
            constraint.priority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)   // ウィンドウの大きさ・最小の大きさの計算に入れない（位置が、窓を広げない）
            offsetConstraints[orientation] = (constraint, base)
            return constraint
        }
        layouts = [
            .top: [
                top.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
                top.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: side),
                along(top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side), base: side, .top),
                top.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -side),
                canvas.topAnchor.constraint(equalTo: top.bottomAnchor, constant: gap),
                canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
                canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
                output.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
                actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
            ],
            .left: [
                top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
                top.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 4),
                along(top.topAnchor.constraint(equalTo: root.topAnchor, constant: 4), base: 4, .left),
                top.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -side),
                canvas.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
                canvas.leadingAnchor.constraint(equalTo: top.trailingAnchor, constant: gap),
                canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
                output.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
            ],
            .right: [
                top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
                top.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 4),
                along(top.topAnchor.constraint(equalTo: root.topAnchor, constant: 4), base: 4, .right),
                top.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -side),
                canvas.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
                canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
                canvas.trailingAnchor.constraint(equalTo: top.leadingAnchor, constant: -gap),
                output.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                actions.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            ],
        ]
        let saved = orientationStore.load()
        activateLayout(for: saved)
        applyOffset(orientationStore.loadOffset(), for: saved)
        toolbar.onPaletteDrag = { [weak self] phase, point in self?.paletteDrag(phase, at: point) }

        // ドラッグ中の、くっつく先の目印。レイアウトには入れず（枠を、直接決める）、ふだんは隠す。
        dropHint.wantsLayer = true
        dropHint.layer?.zPosition = 1   // キャンバスの上、パレットの下
        dropHint.layer?.cornerRadius = FloatingPill.cornerRadius
        dropHint.layer?.borderWidth = 1.5
        dropHint.isHidden = true
        root.addSubview(dropHint)
        dropHint.setAccessibilityElement(false)

        // ビューの帯（倍率の表示・戻す。SPEC §3.2.5）：キャンバスの左下に重ねる。ビューが等倍・移動なしのときは、隠れている
        viewControls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(viewControls, positioned: .above, relativeTo: canvas)
        NSLayoutConstraint.activate([
            viewControls.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 8),
            viewControls.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -8),
        ])
        viewControls.onResetZoom = { [weak self] in self?.canvas.resetZoom() }
        viewControls.onResetView = { [weak self] in self?.canvas.resetViewport() }
        canvas.onViewportChange = { [weak self] viewport in self?.viewControls.show(viewport) }

        panel.contentView = root
        let fitting = root.fittingSize
        panel.setContentSize(fitting)
        panel.contentMinSize = fitting
    }

    /// ツールのパレットの置き場所に合う配置だけを有効にする（大きさは、呼び出し側が合わせる）。
    private func activateLayout(for orientation: PaletteOrientation) {
        for (other, constraints) in layouts where other != orientation { NSLayoutConstraint.deactivate(constraints) }
        self.orientation = orientation
        toolbar.orientation = orientation
        NSLayoutConstraint.activate(layouts[orientation] ?? [])
    }

    /// パレットの置き場所を替える（SPEC §4）。キャンバスの大きさは変えず、ウィンドウを、パレットの分だけ広げる・狭める。
    private func changeOrientation(to orientation: PaletteOrientation) {
        let canvasSize = canvas.canvasSize
        activateLayout(for: orientation)
        let fitting = root.fittingSize   // キャンバスが最小（480×320）のときの、内容の大きさ
        let chrome = CGSize(width: fitting.width - CanvasView.minimumSize.width, height: fitting.height - CanvasView.minimumSize.height)
        panel.contentMinSize = fitting
        sizing.setContentSize(CGSize(width: canvasSize.width + chrome.width, height: canvasSize.height + chrome.height))
    }

    /// 縁に沿った位置（縁の端からの距離）を、置き場所の配置に入れる。
    private func applyOffset(_ offset: CGFloat, for orientation: PaletteOrientation) {
        guard let entry = offsetConstraints[orientation] else { return }
        entry.constraint.constant = entry.base + offset
    }

    // MARK: - パレットのドラッグ（SPEC §4）

    /// ドラッグ中の、くっつく先の目印（その縁に、淡い色の帯）。
    private func paletteDrag(_ phase: FloatingPill.DragPhase, at point: NSPoint) {
        let size = root.bounds.size
        let pointer = CGPoint(x: point.x, y: size.height - point.y)   // 左上が原点
        if phase == .began {
            // パレットを持った所（パレットの始まりから）。離すとき、その所が、ポインタの下に来るようにする（持った所が、ずれない）
            let pill = toolbar.topPill.frame
            let along = orientation.isVertical ? pointer.y - (size.height - pill.maxY) : pointer.x - pill.minX
            grab = max(along, 0)
            dragStartOrientation = orientation
        }
        let zone = PaletteDock.orientation(forPointer: pointer, in: size, current: orientation)
        switch phase {
        case .began, .moved:
            showDropHint(zone, in: size)
        case .ended:
            dropHint.isHidden = true
            dropPalette(at: zone, pointer: pointer)
        }
    }

    private func showDropHint(_ zone: PaletteOrientation, in size: CGSize) {
        let thickness: CGFloat = zone.isVertical ? 60 : 44
        let frame: NSRect
        switch zone {
        case .top: frame = NSRect(x: Self.side, y: size.height - 4 - thickness, width: size.width - 2 * Self.side, height: thickness)
        case .left: frame = NSRect(x: Self.side, y: Self.side, width: thickness, height: size.height - 4 - Self.side)
        case .right: frame = NSRect(x: size.width - Self.side - thickness, y: Self.side, width: thickness, height: size.height - 4 - Self.side)
        }
        dropHint.frame = frame
        dropHint.isHidden = false
    }

    /// 離した所に近い縁へ、パレットをくっつける。縁に沿った位置は、持った所がポインタの下に来るようにする（縁の中に収める）。
    /// 別の縁へ移すときは、持った所を、始まりの近く（`maxGrab` まで）に丸める（向きが替わると、パレットの長さ・形が違うため）。
    /// 縁に沿った余りは、パレットのいちばん長い形（大きさの部品が出ているとき）で決める（あとで部品が出ても、ツールのボタンが動かないように）。
    private func dropPalette(at zone: PaletteOrientation, pointer: CGPoint) {
        let held = zone == dragStartOrientation ? grab : min(grab, Self.maxGrab)
        if zone != orientation { changeOrientation(to: zone) }
        root.layoutSubtreeIfNeeded()
        let length = toolbar.longestPillLength
        let size = root.bounds.size
        let offset: CGFloat
        if zone.isVertical {
            offset = PaletteDock.offset(pointerAlongEdge: pointer.y, grab: held, palette: length, start: 4, track: size.height - 4 - Self.side)
        } else {
            offset = PaletteDock.offset(pointerAlongEdge: pointer.x, grab: held, palette: length, start: Self.side, track: size.width - 2 * Self.side)
        }
        applyOffset(offset, for: zone)
        orientationStore.save(zone, offset: offset)
    }

    /// 割り当てが変わったとき、ツールチップを新しいキーに合わせる。
    func refreshHints() {
        toolbar.showHints(center)
    }

    // MARK: - キー入力

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        let action = KeyRouter.route(
            chord, bindings: center.bindings,
            isEditingText: canvas.isEditing, isComposingText: canvas.isComposingText
        )
        switch action {
        case .passThrough:
            return false
        case .textEditing(let key):
            switch key {
            case .copy: forwardToText(#selector(NSText.copy(_:)))
            case .cut: forwardToText(#selector(NSText.cut(_:)))
            case .selectAll: forwardToText(#selector(NSText.selectAll(_:)))
            }
            return true
        case .cancelTextEditing:
            canvas.cancelEditing()
            return true
        case .run(let command):
            perform(command)
            return true
        }
    }

    private func forwardToText(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: panel)
    }

    // MARK: - コマンド

    /// コマンドを実行する。文字入力中は、文字入力欄の操作として扱うものと、無視するものがある。
    func perform(_ command: Command) {
        let editing = canvas.isEditing
        switch command {
        case .showPanel:
            show()
        case .hidePanel:
            if editing { canvas.cancelEditing() } else { panel.orderOut(nil) }
        case .undo:
            if editing { forwardToText(Selector(("undo:"))) } else { canvas.undo() }
        case .redo:
            if editing { forwardToText(Selector(("redo:"))) } else { canvas.redo() }
        case .clearCanvas:
            canvas.clearCanvas()
        case .pasteImage:
            if editing { forwardToText(#selector(NSText.paste(_:))) } else { canvas.pasteImages() }
        case .openImage:
            if !editing { pickImages() }
        case .copyPath:
            copyPath()
        case .toolPen: select(.pen)
        case .toolEllipse: select(.ellipse)
        case .toolRect: select(.rect)
        case .toolTriangle: select(.triangle)
        case .toolHand: select(.hand)
        case .toolEraser: select(.eraser)
        case .toolNumber: select(.number)
        case .viewReset: canvas.resetViewport()
        case .toolText: select(.text)
        case .toolMove: select(.move)
        case .toolLine: select(.line)
        case .brushSmaller: adjustBrush(by: -Self.brushStep)
        case .brushLarger: adjustBrush(by: Self.brushStep)
        }
    }

    private func select(_ tool: Tool) {
        canvas.tool = tool
        toolbar.show(tool: tool)
    }

    private func adjustBrush(by delta: CGFloat) {
        let range = Toolbar.brushRange
        let size = min(max(canvas.brushSize + delta, range.lowerBound), range.upperBound)
        canvas.brushSize = size
        toolbar.show(brushSize: size)
    }

    /// 画像ファイルを選んで、キャンバスの中央に追加する（貼り付け・ドロップと同じ扱い）。
    private func pickImages() {
        canvas.commitEditing()
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.message = "キャンバスに追加する画像を選んでください"
        NSApp.activate(ignoringOtherApps: true)
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK else { return }
            self?.canvas.addImages(at: open.urls)
        }
    }

    private func copyPath() {
        guard let url = exportFile() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        toolbar.flashCopied()
    }

    // MARK: - キャンバスのサイズ

    /// 保存してあるサイズ（メニューのチェック表示用）。
    var savedCanvasSize: CanvasSize { sizeStore.load() }

    /// キャンバスのサイズを設定する。有効なら適用して、次回の起動のために保存する。無効なら理由を知らせる。
    func requestCanvasSize(width: Int, height: Int) {
        let limits = sizing.limits
        switch CanvasSize.parse(width: width, height: height, limits: limits) {
        case .success(let size):
            sizing.apply(size)
            sizeStore.save(size)
        case .failure(let error):
            CanvasSizeDialog.showError(error, limits: limits)
        }
    }

    /// 数値でキャンバスのサイズを入力する。
    func promptCanvasSize() {
        guard let input = CanvasSizeDialog.prompt(current: savedCanvasSize, limits: sizing.limits) else { return }
        requestCanvasSize(width: input.width, height: input.height)
    }

    // MARK: - 公開

    func show() {
        if !positioned {
            panel.center()
            positioned = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !canvas.isEditing { panel.makeFirstResponder(canvas) }   // 文字入力中なら、フォーカスを入力欄から奪わない
    }

    @discardableResult
    func load(_ url: URL) -> Bool {
        panel.contentView?.layoutSubtreeIfNeeded()  // 背景画像の配置は、読み込み時のキャンバスの大きさで決まる
        return canvas.loadImage(at: url)
    }

    /// 最新の PNG のファイル。変更がなければ前回書き出したものを返す。書き出せなければビープして `nil`。
    func exportFile() -> URL? {
        canvas.commitEditing()  // 入力中の文字を含めて書き出す。確定でキャッシュは無効になる
        switch exportStore.url(render: { canvas.renderPNG() }) {
        case .success(let url):
            return url
        case .failure:
            NSSound.beep()
            return nil
        }
    }
}

// MARK: - エージェントの操作（SPEC §3.7）

extension PaintWindowController: AgentCanvas {
    /// ウィンドウを前面に出す。アプリを前面にしない・キーにしない（人の入力先を、奪わない）。
    func showWithoutActivating() {
        if !positioned {
            panel.center()
            positioned = true
        }
        panel.orderFrontRegardless()
    }

    var agentCanvasSize: CGSize { canvas.canvasSize }

    func agentAppend(_ items: [Item]) {
        canvas.appendFromAgent(items)
        showWithoutActivating()   // 人が見ているキャンバスに出す
    }

    func agentClear() -> Bool { canvas.clearFromAgent() }

    func agentSnapshot() -> AgentSnapshot {
        let document = canvas.committedDocument
        return AgentSnapshot(
            size: canvas.canvasSize,
            background: document.background == nil ? nil : document.backgroundRect,
            editing: canvas.isInteracting,
            items: document.items
        )
    }

    func agentExport() -> URL? {
        if case .success(let url) = exportStore.url(render: { canvas.renderCommittedPNG() }) { return url }
        return nil
    }
}
