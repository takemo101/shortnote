import Foundation
import Testing
@testable import ShortNoteKit

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite("--help と --version")
struct HelpTests {
    private func run(_ args: [String], version: String = "ShortNote 9.9.9") -> (code: Int32, out: [String]) {
        let lines = Lines()
        let code = AgentCLI.run(args, socketPath: "/tmp/snt-help-none.sock", launch: { false }, output: { lines.add($0) }, versionText: version)
        return (code, lines.all)
    }

    @Test("help・--help・-h は、使い方を出して 0。--version・-V・version は、版を出して 0（アプリを起動する名前ではない）")
    func helpAndVersionNames() {
        for name in ["help", "--help", "-h"] {
            let r = run([name])
            #expect(r.code == 0 && r.out.count == 1 && r.out[0].contains("Usage:"), "\(name)")
            #expect(AgentCLI.handles(name))
        }
        for name in ["version", "--version", "-V"] {
            let r = run([name])
            #expect(r.code == 0 && r.out == ["ShortNote 9.9.9"], "\(name)")
            #expect(AgentCLI.handles(name))
        }
    }

    @Test("全体の説明は、すべてのコマンドを載せ、コマンドごとの説明がある（コマンドを足して、説明を忘れると、ここで気づく）")
    func everyCommandIsDocumented() {
        let all = ["render"] + LiveCommand.names.sorted()
        for command in all {
            #expect(HelpText.overview.contains("snote \(command)"), "overview: \(command)")
            #expect(HelpText.commands[command]?.hasPrefix("Usage: snote \(command)") == true, "help: \(command)")
            #expect(run(["help", command]).out == [HelpText.commands[command]!])
            #expect(run([command, "--help"]).out == [HelpText.commands[command]!], "\(command) --help")
            #expect(run([command, "-h"]).code == 0)
        }
        #expect(Set(HelpText.commands.keys) == Set(all))
    }

    @Test("--help は、他の引数があっても、実行せずに説明を出す（render --help は、出力を書かない・アプリに触れない）")
    func helpNeverRunsTheCommand() {
        let r = run(["render", "-", "/no/such/ops.json", "-o", "/tmp/snt-help-out.png", "--help"])
        #expect(r.code == 0 && r.out == [HelpText.commands["render"]!])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/snt-help-out.png"))
        #expect(run(["draw", "-", "-h"]).code == 0)   // 標準入力を読まず、アプリにも届かない（launch が false でも 0）
    }

    @Test("知らないコマンドの help や、余計な引数は、usage（終了コード 2）。何も出力しない")
    func badHelpUsage() {
        for args in [["help", "bogus"], ["help", "draw", "extra"], ["version", "x"], ["--version", "--help2"]] {
            let r = run(args)
            #expect(r.code == 2 && r.out.isEmpty, "\(args)")
        }
    }

    @Test("版の表示：Info.plist の CFBundleShortVersionString。アプリの外では、分からない旨")
    func versionText() {
        #expect(HelpText.version(infoDictionary: ["CFBundleShortVersionString": "0.2.0"]) == "ShortNote 0.2.0")
        #expect(HelpText.version(infoDictionary: nil).contains("version unknown"))
        #expect(HelpText.version(infoDictionary: ["CFBundleShortVersionString": ""]).contains("version unknown"))
    }

    @Test("同名の画像ファイルは、これまでどおり ./ をつければアプリの起動のまま（help・version も、先頭の引数が名前そのものの場合だけ）")
    func pathsAreNotCommands() {
        for other in ["./help", "./version", "help.png", "--helpme", "-hh", "--versions", "-v"] { #expect(!AgentCLI.handles(other), "\(other)") }
    }
}
