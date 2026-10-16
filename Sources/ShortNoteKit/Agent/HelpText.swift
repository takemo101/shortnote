import Foundation

/// `--help`・`help [コマンド]` の文面と、`--version` の版（SPEC §3.7）。標準出力に出して、終了コード 0。画面を出さず、アプリを起動しない。
/// 文面は、エージェントも読むので、英語（コマンドの名前・引数・終了コードを、そのまま載せる）。エラーメッセージは、これまでどおり日本語。
enum HelpText {
    /// 名前は、`snote`（入れていなければ、実行ファイルのフルパス）。
    static let overview = """
    ShortNote - a macOS menu-bar sticky-note paint tool. This executable is also a CLI (installed as `snote` from the menu-bar menu).

    Usage:
      snote render [--size WxH] [--transparent] <background image | -> <ops JSON file | -> -o <out.png>
      snote draw <ops JSON file | ->
      snote get
      snote export
      snote clear
      snote help [command]        (also: --help, -h)
      snote version               (also: --version, -V)

    Commands:
      render   Annotate an image (or a blank page) and write a PNG. Needs no running app.
      draw     Add the operations to the canvas of the running app (starts it if needed, without taking focus).
      get      Print the committed canvas as JSON (size, background, items, editing).
      export   Write the committed canvas to a PNG and print its path.
      clear    Remove everything drawn (the background stays). The human can undo it.

    Run `snote help <command>` for a command's details. Without arguments, `snote` starts the app.
    Operations JSON: {"version":1,"ops":[{"op":"rect","x":40,"y":60,"w":200,"h":80,"color":"#ff0000"}, ...]}
    ops: pen, line, ellipse, rect, text, image. Coordinates are canvas points (origin top-left; 1 pt = 2 px in exported PNGs).

    Exit codes: 0 ok, 1 invalid ops JSON (nothing applied), 2 usage, 3 cannot reach the app, 4 file I/O.
    Errors are one JSON line on stderr: {"error":{"code","message","op"?}}. Success is one JSON line on stdout.
    To open an image file named like a command (render, draw, ...), pass it as a path such as ./draw.
    """

    static let commands: [String: String] = [
        "render": """
        Usage: snote render [--size WxH] [--transparent] <background image | -> <ops JSON file | -> -o <out.png>

        Draws the operations on top of the background image and writes a PNG. Runs in this process only; it never talks to the app.
          <background image>  A file path, or `-` for a blank page.
          <ops JSON file>     A file path, or `-` to read stdin.
          -o <out.png>        Output path (required, once).
          --size WxH          Canvas size in pixels (default 960x640; both even, at least 960x640, long side at most 8192).
                              Use the background image's pixel size to make it fill the canvas: 1 pt in ops = 2 px of the image.
          --transparent       Make blank areas transparent.
        Prints {"path","width","height","clamped":[...],"skipped":[...]}.
        """,
        "draw": """
        Usage: snote draw <ops JSON file | ->

        Adds the operations to the running app's canvas as one undo step. Starts the app (without taking keyboard focus) if it is not running,
        and waits up to 5 s for it. Works while the human is typing or dragging, without breaking their input.
        Relative `image` paths are made absolute from the current directory.
        Prints {"added":N,"clamped":[...],"skipped":[...]}.
        """,
        "get": """
        Usage: snote get

        Prints the committed canvas: {"canvas":{"width","height"},"background":{"x","y","w","h"}|null,"editing":bool,"items":[...]}.
        `items` use the same shape as the ops JSON, plus `index` (0 is the bottom). Does not change the canvas. Needs the app running.
        """,
        "export": """
        Usage: snote export

        Writes the committed canvas (background and drawings) to a PNG and prints {"path":"/tmp/shortnote/note-....png"}.
        The PNG is 2 px per canvas point. If nothing changed since the last export, the same path is returned. Needs the app running.
        """,
        "clear": """
        Usage: snote clear

        Removes everything drawn, including what the human drew; the background image stays. The human can undo it with Cmd+Z.
        Prints {"cleared":true|false} (false when there was nothing to remove). Needs the app running.
        """,
    ]

    /// `topic` なし：全体。コマンド名：そのコマンドの説明。知らない名前は `nil`。
    static func text(for topic: String?) -> String? {
        guard let topic else { return overview }
        if topic == "help" || topic == "version" { return overview }
        return commands[topic]
    }

    /// 版の表示（`ShortNote 0.2.0`）。`Info.plist` の `CFBundleShortVersionString`。アプリの外（`swift run` など）では、版が分からない旨。
    static func version(infoDictionary: [String: Any]?) -> String {
        guard let short = infoDictionary?["CFBundleShortVersionString"] as? String, !short.isEmpty else {
            return "ShortNote (version unknown: not running from an app bundle)"
        }
        return "ShortNote \(short)"
    }

    /// このプロセスのアプリの版。リンク（`snote`）経由でも、リンクを辿ったアプリの `Info.plist` を読む。
    static var currentVersion: String {
        let info = AppLocation.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? Bundle.main.infoDictionary
        return version(infoDictionary: info)
    }
}
