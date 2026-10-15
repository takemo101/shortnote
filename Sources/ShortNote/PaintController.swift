import AppKit

/// Esc で隠す、Cmd/Ctrl+Z・Shift+Z で Undo/Redo、Cmd+V で画像貼り付け。
/// メニューバーを持たないアプリなので、フォーカス位置に関わらず効かせるため sendEvent で拾う。
/// 文字入力中は Esc=入力取り消し、Cmd+V/C/X/A/Z は文字入力欄に渡す。
final class PaintPanel: NSPanel {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCancelEdit: (() -> Void)?
    var isEditingText: () -> Bool = { false }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let editing = isEditingText()
            if event.keyCode == 53 {  // Esc
                if editing { onCancelEdit?() } else { orderOut(nil) }
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags.contains(.command) || flags.contains(.control) {
                switch key {
                case "z":
                    if editing {
                        NSApp.sendAction(Selector(flags.contains(.shift) ? "redo:" : "undo:"), to: nil, from: self)
                    } else if flags.contains(.shift) {
                        onRedo?()
                    } else {
                        onUndo?()
                    }
                    return
                case "v" where flags.contains(.command):
                    if editing { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) } else { onPaste?() }
                    return
                case "c" where flags.contains(.command) && editing:
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                    return
                case "x" where flags.contains(.command) && editing:
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
                    return
                case "a" where flags.contains(.command) && editing:
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                    return
                default:
                    break
                }
            }
        }
        super.sendEvent(event)
    }
}

final class PaintController: NSObject {
    static let outputDirectory = URL(fileURLWithPath: "/tmp/shortnote", isDirectory: true)

    private let panel: PaintPanel
    private let canvas = CanvasView(frame: NSRect(origin: .zero, size: CanvasView.canvasSize))
    private let copyButton = NSButton(title: "パスをコピー", target: nil, action: nil)
    private var cachedURL: URL?
    private var positioned = false

    override init() {
        panel = PaintPanel(
            contentRect: NSRect(origin: .zero, size: CanvasView.canvasSize),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildUI()
    }

    // MARK: - UI

    private func buildUI() {
        panel.title = "ShortNote"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onUndo = { [weak self] in self?.canvas.undo() }
        panel.onRedo = { [weak self] in self?.canvas.redo() }
        panel.onPaste = { [weak self] in self?.canvas.pasteImages() }
        panel.onCancelEdit = { [weak self] in self?.canvas.cancelEditing() }
        panel.isEditingText = { [weak self] in self?.canvas.isEditing ?? false }

        canvas.onChange = { [weak self] in self?.cachedURL = nil }
        canvas.widthAnchor.constraint(equalToConstant: CanvasView.canvasSize.width).isActive = true
        canvas.heightAnchor.constraint(equalToConstant: CanvasView.canvasSize.height).isActive = true

        // ツール切替
        let tools = NSSegmentedControl(
            images: ["pencil.tip", "circle", "square", "textformat", "arrow.up.and.down.and.arrow.left.and.right"].map {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()
            },
            trackingMode: .selectOne,
            target: self,
            action: #selector(toolChanged(_:))
        )
        tools.selectedSegment = 0
        ["ペン", "円", "四角", "文字", "移動"].enumerated().forEach { tools.setToolTip($1, forSegment: $0) }
        tools.refusesFirstResponder = true

        // 色
        let well = NSColorWell(style: .minimal)
        well.color = canvas.color
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.refusesFirstResponder = true
        well.widthAnchor.constraint(equalToConstant: 36).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // ブラシサイズ
        let slider = NSSlider(value: Double(canvas.brushSize), minValue: 1, maxValue: 40, target: self, action: #selector(sizeChanged(_:)))
        slider.refusesFirstResponder = true
        slider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        slider.toolTip = "ブラシサイズ"

        // 背景透過
        let transparent = NSButton(checkboxWithTitle: "背景透過", target: self, action: #selector(transparentChanged(_:)))
        transparent.refusesFirstResponder = true

        let top = NSStackView(views: [tools, well, slider, transparent])
        top.orientation = .horizontal
        top.spacing = 12
        top.alignment = .centerY

        // 下段: ドラッグ / コピー
        let handle = DragHandleView()
        handle.fileProvider = { [weak self] in self?.exportFile() }

        copyButton.target = self
        copyButton.action = #selector(copyPath)
        copyButton.bezelStyle = .rounded
        copyButton.refusesFirstResponder = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [handle, spacer, copyButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [top, canvas, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        bottom.widthAnchor.constraint(equalToConstant: CanvasView.canvasSize.width).isActive = true

        panel.contentView = root
        panel.setContentSize(root.fittingSize)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.tool = Tool(rawValue: sender.selectedSegment) ?? .pen
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.color = sender.color
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        canvas.brushSize = CGFloat(sender.doubleValue)
    }

    @objc private func transparentChanged(_ sender: NSButton) {
        canvas.transparent = sender.state == .on
    }

    @objc private func copyPath() {
        guard let url = exportFile() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)

        copyButton.title = "コピーしました"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "パスをコピー"
        }
    }

    // MARK: - Public

    func show() {
        if !positioned {
            panel.center()
            positioned = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
    }

    @discardableResult
    func load(_ url: URL) -> Bool {
        canvas.loadImage(at: url)
    }

    /// 変更がなければ前回書き出した PNG をそのまま返す。
    func exportFile() -> URL? {
        canvas.commitEditing()  // 入力中の文字を含めて書き出す。確定で cachedURL は無効になる
        if let cachedURL, FileManager.default.fileExists(atPath: cachedURL.path) { return cachedURL }
        guard let data = canvas.renderPNG() else { return nil }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let url = Self.outputDirectory.appendingPathComponent("note-\(f.string(from: Date())).png")
            try data.write(to: url, options: .atomic)
            cachedURL = url
            return url
        } catch {
            NSSound.beep()
            return nil
        }
    }
}
