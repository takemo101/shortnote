import AppKit

/// パネル（ツールバー＋キャンバス）の組み立てと、コマンドの実行。
/// ツールバーの操作もショートカットも、同じ `perform(_:)` を通る。
final class PaintWindowController: NSObject {
    private let panel: PaintPanel
    private let canvas = CanvasView(frame: NSRect(origin: .zero, size: CanvasView.minimumSize))
    private let toolbar = Toolbar()
    private let exportStore = ExportStore()
    private let sizeStore = CanvasSizeStore()
    private let center: ShortcutCenter
    private lazy var sizing = CanvasSizing(panel: panel, canvas: canvas)
    private var positioned = false

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
            if tool == .ellipse { self?.canvas.fillEllipse = filled } else if tool == .rect { self?.canvas.fillRect = filled }
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

        // キャンバスだけが、ウィンドウの大きさに合わせて伸び縮みする（上下の帯は固定の高さ）。
        let top = toolbar.topRow, bottom = toolbar.bottomRow
        let root = NSView()
        for v in [top, canvas, bottom] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let side: CGFloat = 12, gap: CGFloat = 8
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            top.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -side),

            canvas.topAnchor.constraint(equalTo: top.bottomAnchor, constant: gap),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),

            bottom.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: gap),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        panel.contentView = root
        let fitting = root.fittingSize
        panel.setContentSize(fitting)
        panel.contentMinSize = fitting
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

    var agentCanvasSize: CGSize { canvas.bounds.size }

    func agentAppend(_ items: [Item]) {
        canvas.appendFromAgent(items)
        showWithoutActivating()   // 人が見ているキャンバスに出す
    }

    func agentClear() -> Bool { canvas.clearFromAgent() }

    func agentSnapshot() -> AgentSnapshot {
        let document = canvas.committedDocument
        return AgentSnapshot(
            size: canvas.bounds.size,
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
