import AppKit

/// アプリを起動する（実行ファイルの `main.swift` から呼ぶ）。メニューバーに常駐し、Dock には出さない。
public func runShortNote() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
