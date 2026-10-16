import AppKit

/// アプリを起動する（実行ファイルの `main.swift` から呼ぶ）。メニューバーに常駐し、Dock には出さない。
/// 最初の引数が CLI のサブコマンド（SPEC §3.7）なら、画面を出さずに、その CLI として動いて終了する。
public func runShortNote() {
    reexecThroughSymlink()
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

/// `snote` のように、実行ファイルへのシンボリックリンクから起動されたときは、リンクを辿った実行ファイルで、自分を置き換える（`exec`）。
/// リンク経由だと、`Bundle.main` が、リンクの場所を基準にして、アプリ（バンドル ID・リソース）を見つけられず、
/// 引数なし・画像のパスつきの起動が、別のバンドル ID の、本番と衝突するインスタンスになってしまうため。
/// 引数・環境・作業ディレクトリ・標準入出力は、そのまま。置き換えたあとは、リンクを辿ったパスなので、二度目はしない（環境変数でも、繰り返しを防ぐ）。
private func reexecThroughSymlink() {
    let guardKey = "SHORTNOTE_REEXEC"
    guard getenv(guardKey) == nil, let path = AppLocation.executablePath, AppLocation.bundleURL(forExecutable: path) != nil else { return }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard resolved != path else { return }
    setenv(guardKey, "1", 1)
    execv(resolved, CommandLine.unsafeArgv)
    unsetenv(guardKey)   // exec できなかった。そのまま続ける
}
