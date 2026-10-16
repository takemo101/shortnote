import Darwin
import Foundation

/// このプロセスの実行ファイルがある、アプリ（`.app`）の場所。
/// `snote` のように、実行ファイルへのシンボリックリンクから起動されたとき、`Bundle.main` は、リンクの場所を基準にして、アプリを見つけられない。
/// そこで、実行ファイルのパスを、リンクを辿って解決し、それを含む `.app` を探す。
enum AppLocation {
    /// `executablePath`（シンボリックリンクでもよい）を、リンクを辿った先にして、それを含む `.app`（`<名前>.app/Contents/MacOS/<実行ファイル>` の形）を返す。
    /// アプリの中でなければ `nil`（`swift run` など）。
    static func bundleURL(forExecutable executablePath: String) -> URL? {
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let macOS = resolved.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }

    /// このプロセスの実行ファイルのパス（起動に使われたパス。リンクのままのことがある）。
    static var executablePath: String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// このプロセスのアプリ。リンク経由でも見つかる。アプリの外なら `nil`。
    static var bundleURL: URL? { executablePath.flatMap { bundleURL(forExecutable: $0) } }

    /// このプロセスのアプリのバンドル ID。アプリの外では、`Bundle.main` のもの（無ければ `nil`）。
    static var bundleIdentifier: String? {
        bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? Bundle.main.bundleIdentifier
    }
}
