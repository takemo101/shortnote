import AppKit

/// メニューバーのアイコンとメニュー。何をするかはコールバックで知らせるだけ。
final class StatusMenu: NSObject, NSMenuDelegate {
    var onOpen: (() -> Void)?
    var onSelectSize: ((CanvasSize) -> Void)?
    var onCustomSize: (() -> Void)?
    var onShowShortcuts: (() -> Void)?
    /// 保存中のキャンバスのサイズ（開くたびに、チェック表示に使う）。
    var savedSize: () -> CanvasSize = { .standard }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        statusItem.button?.image = Self.menuBarIcon()

        let menu = NSMenu()
        menu.addItem(item("ShortNote を開く", #selector(openPressed)))
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        // キャンバスのサイズ（書き出す PNG のピクセル数）。選んだサイズは次回の起動でも使う。
        let sizeItem = NSMenuItem(title: "キャンバスサイズ", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "キャンバスサイズ")
        sizeMenu.delegate = self
        for (index, preset) in CanvasSize.presets.enumerated() {
            let presetItem = item(preset.title, #selector(presetPressed(_:)))
            presetItem.tag = index
            sizeMenu.addItem(presetItem)
        }
        sizeMenu.addItem(.separator())
        sizeMenu.addItem(item("数値で指定…", #selector(customPressed)))   // 末尾の項目。menuNeedsUpdate が、保存中の数値を表示に反映する
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(item("ショートカット…", #selector(shortcutsPressed)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// メニューバーのアイコン。アプリのバンドルに入れた単色の画像（`MenuBarIcon.png`。`scripts/make-icon.sh` で生成）を、
    /// テンプレート画像として使う（ダーク／ライトのメニューバーに、色が追従する）。
    /// バンドルの外（`swift run` など）では、画像が無いので、システムのシンボルで代える（開発用の経路だけ）。
    static func menuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)   // 画像は 72 px（4 倍）。ポイントの大きさを 18 にする
            image.isTemplate = true
            image.accessibilityDescription = "ShortNote"
            return image
        }
        return NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "ShortNote") ?? NSImage()
    }

    /// 「ウィンドウを出す」全域キーの状態を表示する。
    func showGlobalKey(_ chord: KeyChord?, registered: Bool) {
        switch (chord, registered) {
        case (nil, _): hint.title = "ウィンドウを出すキー: なし"
        case (let chord?, true): hint.title = "ウィンドウを出すキー: \(chord.displayString)"
        case (let chord?, false): hint.title = "ウィンドウを出すキー: 登録できませんでした（\(chord.displayString)）"
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openPressed() { onOpen?() }
    @objc private func customPressed() { onCustomSize?() }
    @objc private func shortcutsPressed() { onShowShortcuts?() }

    @objc private func presetPressed(_ sender: NSMenuItem) {
        guard CanvasSize.presets.indices.contains(sender.tag) else { return }
        onSelectSize?(CanvasSize.presets[sender.tag].size)
    }

    /// 開くたびに、保存中のサイズにチェックを付ける。プリセットに無いサイズなら、末尾の「数値で指定…」に数値を出してチェックする。
    func menuNeedsUpdate(_ menu: NSMenu) {
        let saved = savedSize()
        var matchedPreset = false
        for menuItem in menu.items where CanvasSize.presets.indices.contains(menuItem.tag) && menuItem.action == #selector(presetPressed(_:)) {
            let matches = CanvasSize.presets[menuItem.tag].size == saved
            menuItem.state = matches ? .on : .off
            matchedPreset = matchedPreset || matches
        }
        if let custom = menu.items.last {
            custom.state = matchedPreset ? .off : .on
            custom.title = matchedPreset ? "数値で指定…" : "数値で指定…（\(saved.width) × \(saved.height)）"
        }
    }
}
