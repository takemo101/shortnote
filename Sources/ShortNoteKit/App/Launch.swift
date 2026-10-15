import AppKit

/// アプリを起動する（実行ファイルの `main.swift` から呼ぶ）。メニューバーに常駐し、Dock には出さない。
/// 最初の引数が CLI のサブコマンド（SPEC §3.7）なら、画面を出さずに、その CLI として動いて終了する。
public func runShortNote() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if let first = arguments.first, AgentCLI.handles(first) {
        exit(AgentCLI.run(arguments))
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // NSApplication.delegate は弱参照。run() が戻るまで、delegate を確実に生かしておく。
    withExtendedLifetime(delegate) { app.run() }
}
