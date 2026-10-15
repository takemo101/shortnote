import AppKit

/// 2 つ目以降の起動（CLI 引数つき含む）から、常駐中のインスタンスへ表示/画像読み込みを依頼する。
/// 通知名は bundle ID から決める（本番は dev.takemo101.shortnote.open）。ID の違うコピー（検証用など）とは混ざらない。
private let openNotification = Notification.Name("\(Bundle.main.bundleIdentifier ?? "dev.takemo101.shortnote").open")

/// 起動と終了、常駐インスタンスへの引き渡し、全域ホットキー、メニューとウィンドウの結びつけ。
final class AppDelegate: NSObject, NSApplicationDelegate {
    // `[` `]` の既定は、いまのキーボード配列（US・JIS など）で、その文字を出すキーにする。
    private let shortcuts = ShortcutCenter(store: KeyBindingsStore(
        defaultChords: {
            let table = KeyboardLayout.characters()   // 配列は 1 度だけ引く
            return KeyBindings.standardDefaults(characterForKeyCode: { table[$0] })
        }()
    ))
    // `open` 経由の起動では application(_:open:) が didFinishLaunching より先に来るため lazy。
    private lazy var controller = PaintWindowController(center: shortcuts)
    private lazy var shortcutsWindow = ShortcutsWindowController(center: shortcuts)
    private var statusMenu: StatusMenu?
    private var hotKey: GlobalHotKey?
    private var agentService: AgentService?
    private var agentServer: AgentServer?

    /// CLI 引数のうち存在するファイルを絶対パスにして返す（cwd 基準）。
    private func cliPaths() -> [String] {
        CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if forwardToRunningInstance() { return }

        let statusMenu = StatusMenu()
        statusMenu.savedSize = { [weak self] in self?.controller.savedCanvasSize ?? .standard }
        statusMenu.onOpen = { [weak self] in self?.controller.show() }
        statusMenu.onSelectSize = { [weak self] size in
            self?.controller.requestCanvasSize(width: size.width, height: size.height)
            self?.controller.show()
        }
        statusMenu.onCustomSize = { [weak self] in
            self?.controller.show()
            self?.controller.promptCanvasSize()
        }
        statusMenu.onShowShortcuts = { [weak self] in self?.shortcutsWindow.show() }
        self.statusMenu = statusMenu

        hotKey = GlobalHotKey { [weak self] in self?.controller.show() }
        shortcuts.onChange = { [weak self] in self?.shortcutsChanged() }
        syncGlobalKey()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteOpen(_:)), name: openNotification, object: nil
        )

        startAgentServer()

        // 起動したらすぐ描けるよう、ウィンドウは毎回出す（画像を渡されたら背景として開く）。CLI の `draw` が起動したときは、フォーカスを奪わない。
        if let path = cliPaths().first {
            controller.load(URL(fileURLWithPath: path))
        }
        if CommandLine.arguments.contains(AppLaunch.noActivateFlag) {
            controller.showWithoutActivating()
        } else {
            controller.show()
        }
    }

    /// エージェントからの操作（SPEC §3.7）を受ける、ソケットを開く。開けなくても、アプリは使える（理由を標準エラーに出す）。
    private func startAgentServer() {
        let service = AgentService(canvas: controller)
        let server = AgentServer(path: AgentSocket.path(bundleID: Bundle.main.bundleIdentifier)) { service.handle($0) }
        switch server.start() {
        case .success:
            agentService = service
            agentServer = server
        case .failure(let error):
            FileHandle.standardError.write(Data("ShortNote: エージェント用のソケットを開けません：\(error)\n".utf8))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentServer?.stop()
    }

    /// 割り当てが変わったら、全域ホットキー・メニュー・ツールチップ・設定ウィンドウの表示を合わせる。
    private func shortcutsChanged() {
        syncGlobalKey()
        controller.refreshHints()
        shortcutsWindow.refresh()
    }

    /// 「ウィンドウを出す」を全域ホットキーに登録し直す。キーの記録中は外す（記録するキーが先に奪われないように）。
    private func syncGlobalKey() {
        guard let hotKey else { return }
        let chord = shortcuts.chords(for: .showPanel).first
        if shortcuts.isRecording {
            hotKey.unregister()
            return
        }
        var registered = false
        if let chord { registered = hotKey.register(chord) } else { hotKey.unregister() }
        shortcuts.isGlobalKeyRegistered = chord == nil || registered
        statusMenu?.showGlobalKey(chord, registered: registered)
    }

    /// 既に常駐しているなら、そちらに依頼して自分は終了する。
    private func forwardToRunningInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return false }

        var info: [String: String] = [:]
        if let path = cliPaths().first { info["path"] = path }
        DistributedNotificationCenter.default().postNotificationName(
            openNotification, object: nil, userInfo: info, deliverImmediately: true
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        NSApp.terminate(nil)
        return true
    }

    @objc private func remoteOpen(_ note: Notification) {
        if let path = note.userInfo?["path"] as? String {
            controller.load(URL(fileURLWithPath: path))
        }
        controller.show()
    }

    // `open -a ShortNote image.png` / Dock・Finder からのファイルオープン
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.isFileURL }) { controller.load(url) }
        controller.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }
}
