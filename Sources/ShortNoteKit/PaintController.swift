import AppKit
import UniformTypeIdentifiers

/// Esc で隠す、Cmd/Ctrl+Z・Shift+Z で Undo/Redo、Cmd+V で画像貼り付け、Cmd+O で画像ファイルの選択。
/// メニューバーを持たないアプリなので、フォーカス位置に関わらず効かせるため sendEvent で拾う。
/// 文字入力中は Esc=入力取り消し、Cmd+V/C/X/A/Z は文字入力欄に渡す。
final class PaintPanel: NSPanel {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onPaste: (() -> Void)?
    var onOpen: (() -> Void)?
    var onCancelEdit: (() -> Void)?
    var isEditingText: () -> Bool = { false }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let editing = isEditingText()
            if event.keyCode == 53 {  // Esc
                // 日本語入力の変換中は、Esc を入力システムに渡す（変換だけを取り消し、入力中の文字は消さない）。
                if editing, (firstResponder as? NSTextView)?.hasMarkedText() == true {
                    super.sendEvent(event)
                    return
                }
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
                case "o" where flags.contains(.command):
                    if !editing { onOpen?() }
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
    private let canvas = CanvasView(frame: NSRect(origin: .zero, size: CanvasView.minimumSize))
    private let copyButton = NSButton(title: "パスをコピー", target: nil, action: nil)
    private var cachedURL: URL?
    private var positioned = false

    override init() {
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
        let saved = Self.savedCanvasPx()
        if !applyCanvasPx(saved) {
            let maxPx = maxCanvasPx()
            applyCanvasPx(CGSize(
                width: max(Self.minimumCanvasPx.width, floor(min(saved.width, maxPx.width) / 2) * 2),
                height: max(Self.minimumCanvasPx.height, floor(min(saved.height, maxPx.height) / 2) * 2)
            ))
        }
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
        panel.onOpen = { [weak self] in self?.pickImages() }
        panel.onCancelEdit = { [weak self] in self?.canvas.cancelEditing() }
        panel.isEditingText = { [weak self] in self?.canvas.isEditing ?? false }

        canvas.onChange = { [weak self] in self?.cachedURL = nil }
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            canvas.setContentHuggingPriority(.defaultLow, for: axis)
            canvas.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: CanvasView.minimumSize.width).isActive = true
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: CanvasView.minimumSize.height).isActive = true

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

        // 画像を追加（ファイル選択）
        let pick = NSButton(image: NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "画像を追加") ?? NSImage(), target: self, action: #selector(pickImages))
        pick.bezelStyle = .rounded
        pick.toolTip = "画像を追加…（⌘O）"
        pick.setAccessibilityLabel("画像を追加")
        pick.refusesFirstResponder = true

        let top = NSStackView(views: [tools, pick, well, slider, transparent])
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

        // キャンバスだけが、ウィンドウの大きさに合わせて伸び縮みする（上下の帯は固定の高さ）。
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

    /// 画像ファイルを選んで、キャンバスの中央に追加する（貼り付け・ドロップと同じ扱い）。
    @objc private func pickImages() {
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

    // MARK: - Canvas size

    /// 「キャンバスのサイズ」は、書き出す PNG のピクセル数（= キャンバスのポイント数 × 書き出し倍率 2）。
    static let minimumCanvasPx = CGSize(
        width: CanvasView.minimumSize.width * CanvasView.exportScale,
        height: CanvasView.minimumSize.height * CanvasView.exportScale
    )
    static let defaultCanvasPx = minimumCanvasPx
    static let canvasSizePresets: [(title: String, px: CGSize)] = [
        ("960 × 640（標準）", CGSize(width: 960, height: 640)),
        ("1280 × 720（HD）", CGSize(width: 1280, height: 720)),
        ("1920 × 1080（Full HD）", CGSize(width: 1920, height: 1080)),
        ("1080 × 1080（正方形）", CGSize(width: 1080, height: 1080)),
        ("1024 × 768（4:3）", CGSize(width: 1024, height: 768)),
    ]
    private static let widthKey = "canvasWidthPx"
    private static let heightKey = "canvasHeightPx"

    /// 保存してあるキャンバスのサイズ。無い・不正（最小未満）なら標準。
    static func savedCanvasPx() -> CGSize {
        let d = UserDefaults.standard
        let w = CGFloat(d.integer(forKey: widthKey)), h = CGFloat(d.integer(forKey: heightKey))
        guard w >= minimumCanvasPx.width, h >= minimumCanvasPx.height else { return defaultCanvasPx }
        return CGSize(width: w, height: h)
    }

    private static func saveCanvasPx(_ px: CGSize) {
        let d = UserDefaults.standard
        d.set(Int(px.width.rounded()), forKey: widthKey)
        d.set(Int(px.height.rounded()), forKey: heightKey)
    }

    /// 保存してあるサイズ（メニューのチェック表示用）。
    var savedCanvasPx: CGSize { Self.savedCanvasPx() }

    private var targetScreenFrame: CGRect { (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    /// この画面に収まる最大のキャンバス（px）。ウィンドウの枠（ツールバーなど）を差し引いて求める。
    func maxCanvasPx() -> CGSize {
        panel.contentView?.layoutSubtreeIfNeeded()
        let frame = targetScreenFrame
        let chromeW = panel.frame.width - canvas.bounds.width, chromeH = panel.frame.height - canvas.bounds.height
        // 偶数に切り下げ、書き出しの長辺の上限（8192）を超えないようにする（上限を超えると、書き出しの倍率が下がり、ピクセル数が一致しなくなる）。
        func even(_ v: CGFloat) -> CGFloat { floor(min(v, CanvasView.maxExportSide) / 2) * 2 }
        return CGSize(
            width: even((frame.width - chromeW) * CanvasView.exportScale),
            height: even((frame.height - chromeH) * CanvasView.exportScale)
        )
    }

    /// ウィンドウを、キャンバスがちょうど `px` になる大きさにする（左上を動かさず、画面からはみ出す分は寄せる）。
    /// 最小未満、またはこの画面に収まらないときは何もせず false。
    @discardableResult
    private func applyCanvasPx(_ px: CGSize) -> Bool {
        let maxPx = maxCanvasPx()
        guard px.width >= Self.minimumCanvasPx.width, px.height >= Self.minimumCanvasPx.height,
              px.width <= maxPx.width, px.height <= maxPx.height,
              px.width.truncatingRemainder(dividingBy: 2) == 0, px.height.truncatingRemainder(dividingBy: 2) == 0 else { return false }   // 奇数はウィンドウの 1x 表示で 1 ピクセルずれるため受け付けない
        let target = CGSize(width: px.width / CanvasView.exportScale, height: px.height / CanvasView.exportScale)
        let cur = canvas.bounds.size
        let old = panel.frame
        let size = CGSize(width: old.width + target.width - cur.width, height: old.height + target.height - cur.height)
        let screen = targetScreenFrame
        var origin = CGPoint(x: old.minX, y: old.maxY - size.height)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        return true
    }

    /// キャンバスのサイズを設定する。適用でき次第、次回の起動のために保存する。収まらないときは理由を知らせる。
    @discardableResult
    func setCanvasSize(px: CGSize) -> Bool {
        if applyCanvasPx(px) {
            Self.saveCanvasPx(px)
            return true
        }
        let maxPx = maxCanvasPx()
        let alert = NSAlert()
        alert.messageText = "このサイズにはできません"
        alert.informativeText = "キャンバスは 最小 \(Int(Self.minimumCanvasPx.width)) × \(Int(Self.minimumCanvasPx.height)) から、この画面では 最大 \(Int(maxPx.width)) × \(Int(maxPx.height)) ピクセルまでです。幅と高さは偶数にしてください（画面では 2 ピクセルが 1 ポイントのため）。"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        return false
    }

    /// 数値でキャンバスのサイズを入力する。
    func promptCanvasSize() {
        let current = savedCanvasPx
        let maxPx = maxCanvasPx()
        let widthField = NSTextField(string: "\(Int(current.width))")
        let heightField = NSTextField(string: "\(Int(current.height))")
        for f in [widthField, heightField] {
            f.alignment = .right
            f.setAccessibilityLabel(f === widthField ? "幅" : "高さ")
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        let row = NSStackView(views: [widthField, NSTextField(labelWithString: "×"), heightField, NSTextField(labelWithString: "ピクセル")])
        row.orientation = .horizontal
        row.spacing = 6
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 24)

        let alert = NSAlert()
        alert.messageText = "キャンバスのサイズ"
        alert.informativeText = "書き出す画像のピクセル数です（最小 \(Int(Self.minimumCanvasPx.width)) × \(Int(Self.minimumCanvasPx.height))、この画面では最大 \(Int(maxPx.width)) × \(Int(maxPx.height))）。次回の起動でも使います。"
        alert.accessoryView = row
        alert.addButton(withTitle: "設定")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let w = Int(widthField.stringValue.trimmingCharacters(in: .whitespaces)),
              let h = Int(heightField.stringValue.trimmingCharacters(in: .whitespaces)) else {
            NSSound.beep()
            return
        }
        setCanvasSize(px: CGSize(width: w, height: h))
    }

    // MARK: - Public

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
