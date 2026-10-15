import AppKit

/// 上を原点にするビュー。スクロールの内容が、ウィンドウの上から並ぶようにする。
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
}

/// ショートカットの設定ウィンドウ。コマンドごとに、いまのキーと「変更…」「なし」「初期値」を並べる。
/// 「変更…」を押すと、次に押したキーを記録して割り当てる（Esc で取り消し）。重なる・予約済みのキーは、理由を出して割り当てない。
final class ShortcutsWindowController: NSObject, NSWindowDelegate {
    private let center: ShortcutCenter
    private let window: NSWindow
    private let list = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var recording: Command?
    private var monitor: Any?
    private var loadIssueShown = false

    init(center: ShortcutCenter) {
        self.center = center
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "ショートカット"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildUI()
        reload()
    }

    /// 割り当てが変わったときに、一覧を作り直す。
    func refresh() {
        reload()
    }

    func show() {
        if !window.isVisible { window.center() }
        if !loadIssueShown, let issue = center.loadIssue {
            loadIssueShown = true
            showMessage(issue, isError: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 組み立て

    private func buildUI() {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false

        let document = TopAnchoredView()   // 上原点にしないと、一覧が下に寄る
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 3
        message.setAccessibilityLabel("ショートカットの案内")
        message.setAccessibilityIdentifier("shortcuts-message")
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let resetAll = NSButton(title: "すべて初期値に戻す", target: self, action: #selector(resetAllPressed))
        resetAll.setAccessibilityIdentifier("shortcuts-reset-all")
        let footer = NSStackView(views: [message, resetAll])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        window.contentView = root
    }

    private func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in CommandGroup.allCases {
            let header = NSTextField(labelWithString: Self.title(of: group))
            header.font = .boldSystemFont(ofSize: 12)
            header.textColor = .secondaryLabelColor
            list.addArrangedSubview(header)
            for command in Command.allCases where command.group == group {
                list.addArrangedSubview(row(for: command))
            }
        }
    }

    private static func title(of group: CommandGroup) -> String {
        switch group {
        case .window: return "ウィンドウ"
        case .edit: return "編集"
        case .image: return "画像"
        case .tool: return "ツール"
        case .brush: return "ブラシ"
        }
    }

    private func row(for command: Command) -> NSView {
        let name = NSTextField(labelWithString: command.title)
        name.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let chords = center.chords(for: command)
        let isRecordingThis = recording == command
        let text = isRecordingThis ? "キーを押してください（Esc で取消）" : (chords.isEmpty ? "なし" : chords.map(\.displayString).joined(separator: " / "))
        let keys = NSTextField(labelWithString: text)
        keys.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        keys.textColor = isRecordingThis ? .controlAccentColor : (chords.isEmpty ? .secondaryLabelColor : .labelColor)
        keys.widthAnchor.constraint(equalToConstant: 170).isActive = true
        keys.setAccessibilityLabel("\(command.title)のキー")
        keys.setAccessibilityIdentifier("keys-\(command.rawValue)")

        let change = button("変更…", command, #selector(changePressed(_:)), id: "change")
        let clear = button("なし", command, #selector(clearPressed(_:)), id: "clear")
        let reset = button("初期値", command, #selector(resetPressed(_:)), id: "reset")
        reset.isEnabled = center.isCustomized(command)

        let stack = NSStackView(views: [name, keys, change, clear, reset])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func button(_ title: String, _ command: Command, _ action: Selector, id: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        b.setAccessibilityIdentifier("\(id)-\(command.rawValue)")
        b.setAccessibilityLabel("\(command.title)：\(title)")
        return b
    }

    // MARK: - 操作

    @objc private func changePressed(_ sender: NSButton) {
        guard let command = command(of: sender) else { return }
        beginRecording(command)
    }

    @objc private func clearPressed(_ sender: NSButton) {
        guard let command = command(of: sender) else { return }
        endRecording()
        center.clear(command)
        showMessage("「\(command.title)」のキーをなしにしました。", isError: false)
    }

    @objc private func resetPressed(_ sender: NSButton) {
        guard let command = command(of: sender) else { return }
        endRecording()
        center.reset(command)
        showMessage("「\(command.title)」を初期値に戻しました。", isError: false)
    }

    @objc private func resetAllPressed() {
        endRecording()
        center.resetAll()
        showMessage("すべて初期値に戻しました。", isError: false)
    }

    private func command(of sender: NSButton) -> Command? {
        sender.identifier.flatMap { Command(rawValue: $0.rawValue) }
    }

    // MARK: - キーの記録

    private func beginRecording(_ command: Command) {
        endRecording()
        recording = command
        center.isRecording = true   // 全域ホットキーを外し、記録するキーが先に奪われないようにする
        showMessage("「\(command.title)」に割り当てるキーを押してください。Esc で取り消します。", isError: false)
        // このウィンドウがキーのときだけ記録する。それ以外のウィンドウのキーは、触らない。
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.record(event) ? nil : event
        }
        reload()
    }

    /// キーを記録する。扱ったら `true`。
    private func record(_ event: NSEvent) -> Bool {
        guard let command = recording, let chord = KeyChord(event: event) else { return false }
        if chord.keyCode == 53, chord.modifiers.isEmpty {   // Esc は取り消し（Esc を割り当てるときは「初期値」から）
            endRecording()
            showMessage("取り消しました。", isError: false)
            return true
        }
        // 記録を終えると全域ホットキーが登録し直されるので、結果の表示は、終えてから決める。
        let result = center.assign(chord, to: command)
        endRecording()
        switch result {
        case .success:
            if command.isGlobal, !center.isGlobalKeyRegistered {
                showMessage("\(chord.displayString) は登録できませんでした。他のアプリが使っている可能性があります。別のキーにしてください。", isError: true)
            } else {
                showMessage("「\(command.title)」を \(chord.displayString) にしました。", isError: false)
            }
        case .failure(let error):
            showMessage(Self.reason(error), isError: true)
        }
        return true
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        center.isRecording = false
        reload()
    }

    private static func reason(_ error: KeyBindings.AssignError) -> String {
        switch error {
        case .conflict(let other): return "「\(other.title)」がすでに使っているキーです。先にそちらを変更するか「なし」にしてください。割り当ては変えていません。"
        case .reserved: return "このキーは OS や文字入力で使われるため、割り当てられません。割り当ては変えていません。"
        case .globalNeedsModifier: return "全域ショートカットには ⌃ ⌥ ⌘ のいずれかが必要です（他のアプリの入力を奪わないため）。割り当ては変えていません。"
        }
    }

    private func showMessage(_ text: String, isError: Bool) {
        message.stringValue = text
        message.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        endRecording()
    }
}
