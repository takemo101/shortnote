import AppKit
import Carbon.HIToolbox

/// 2 つ目以降の起動（CLI 引数つき含む）から、常駐中のインスタンスへ表示/画像読み込みを依頼する。
/// 通知名は bundle ID から決める（本番は dev.takemo101.shortnote.open）。ID の違うコピー（検証用など）とは混ざらない。
private let openNotification = Notification.Name("\(Bundle.main.bundleIdentifier ?? "dev.takemo101.shortnote").open")

final class AppDelegate: NSObject, NSApplicationDelegate {
    // `open` 経由の起動では application(_:open:) が didFinishLaunching より先に来るため lazy。
    private lazy var controller = PaintController()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    /// CLI 引数のうち存在するファイルを絶対パスにして返す（cwd 基準）。
    private func cliPaths() -> [String] {
        CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if forwardToRunningInstance() { return }

        // ⌃⌥N
        hotKey = HotKey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey) { [weak self] in
            self?.controller.show()
        }
        setupStatusItem()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteOpen(_:)), name: openNotification, object: nil
        )

        // 起動したらすぐ描けるよう、ウィンドウは毎回出す（画像を渡されたら背景として開く）。
        if let path = cliPaths().first {
            controller.load(URL(fileURLWithPath: path))
        }
        controller.show()
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

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "ShortNote")

        let menu = NSMenu()
        let open = NSMenuItem(title: "ShortNote を開く", action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let hint = NSMenuItem(title: hotKey == nil ? "ショートカット: 登録できませんでした" : "ショートカット: ⌃⌥N", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        // キャンバスのサイズ（書き出す PNG のピクセル数）。選んだサイズは次回の起動でも使う。
        let sizeItem = NSMenuItem(title: "キャンバスサイズ", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "キャンバスサイズ")
        sizeMenu.delegate = self
        for preset in PaintController.canvasSizePresets {
            let item = NSMenuItem(title: preset.title, action: #selector(selectCanvasSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSValue(size: preset.px)
            sizeMenu.addItem(item)
        }
        sizeMenu.addItem(.separator())
        let custom = NSMenuItem(title: "数値で指定…", action: #selector(customCanvasSize), keyEquivalent: "")
        custom.target = self
        sizeMenu.addItem(custom)   // 末尾の項目。menuNeedsUpdate が、保存中の数値を表示に反映する
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func selectCanvasSize(_ sender: NSMenuItem) {
        guard let px = (sender.representedObject as? NSValue)?.sizeValue else { return }
        controller.setCanvasSize(px: px)
        controller.show()
    }

    @objc private func customCanvasSize() {
        controller.show()
        controller.promptCanvasSize()
    }

    @objc private func showPanel() {
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

extension AppDelegate: NSMenuDelegate {
    /// 開くたびに、保存中のサイズにチェックを付ける。プリセットに無いサイズなら、末尾の「数値で指定…」に数値を出してチェックする。
    func menuNeedsUpdate(_ menu: NSMenu) {
        let saved = controller.savedCanvasPx
        var matchedPreset = false
        for item in menu.items {
            guard let px = (item.representedObject as? NSValue)?.sizeValue else { continue }
            item.state = px == saved ? .on : .off
            if px == saved { matchedPreset = true }
        }
        if let custom = menu.items.last {
            custom.state = matchedPreset ? .off : .on
            custom.title = matchedPreset ? "数値で指定…" : "数値で指定…（\(Int(saved.width)) × \(Int(saved.height))）"
        }
    }
}
