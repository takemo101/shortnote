import Foundation
import Testing
@testable import ShortNoteKit

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    func add(_ command: String) { lock.lock(); commands.append(command); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return commands }
}

/// 試験用の、アプリに見立てたディレクトリ（`X.app/Contents/MacOS/ShortNote`）と、リンクを置く場所。
private struct Sandbox {
    let root: URL
    let executable: String   // リンクを辿ったパス
    let linkDirectory: URL

    init() throws {
        let raw = URL(fileURLWithPath: "/tmp/snt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.resolvingSymlinksInPath()
        let macOS = root.appendingPathComponent("Apps/ShortNote.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = macOS.appendingPathComponent("ShortNote")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        executable = exe.path
        linkDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
    }

    var linkPath: String { linkDirectory.appendingPathComponent("snote").path }
    func cleanup() { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: linkDirectory.path); try? FileManager.default.removeItem(at: root) }
}

@Suite("リンク経由の起動で、アプリを見つける")
struct AppLocationTests {
    @Test("実行ファイルへのシンボリックリンク（snote）からでも、リンクを辿って、それを含む .app が見つかる。アプリの外は nil")
    func findsTheAppThroughSymlinks() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let appPath = URL(fileURLWithPath: box.executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        #expect(AppLocation.bundleURL(forExecutable: box.executable)?.path == appPath)

        try FileManager.default.createSymbolicLink(atPath: box.linkPath, withDestinationPath: box.executable)
        #expect(AppLocation.bundleURL(forExecutable: box.linkPath)?.path == appPath)

        // リンクのリンク（相対パスのリンクを含む）
        let second = box.linkDirectory.appendingPathComponent("again").path
        try FileManager.default.createSymbolicLink(atPath: second, withDestinationPath: "snote")
        #expect(AppLocation.bundleURL(forExecutable: second)?.path == appPath)

        let loose = box.root.appendingPathComponent("tool")
        try Data().write(to: loose)
        #expect(AppLocation.bundleURL(forExecutable: loose.path) == nil)
        #expect(AppLocation.bundleURL(forExecutable: "/usr/bin/true") == nil)
    }
}

@Suite("コマンド snote のリンク")
struct CommandLineToolTests {
    private func tool(_ box: Sandbox, target: String? = nil, admin: @escaping CommandLineTool.AdminRunner = { _ in "管理者の実行は、このテストでは使わない" }) -> CommandLineTool {
        CommandLineTool(linkPath: box.linkPath, target: target ?? box.executable, runAsAdministrator: admin)
    }

    @Test("入れると、アプリの実行ファイルへのリンクができ、外すと消える。入れる前は notInstalled")
    func installAndUninstall() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let t = tool(box)
        #expect(t.state == .notInstalled)
        #expect(t.install() == nil)
        #expect(t.state == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.linkPath) == box.executable)
        #expect(t.install() == nil)   // 2 回目は、何も変えない
        #expect(t.uninstall() == nil)
        #expect(t.state == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: box.linkPath))
    }

    @Test("同じパスに、別のもの（ファイル、別のアプリへのリンク）があるときは、上書きも削除もしない")
    func neverTouchesSomethingElse() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let t = tool(box)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: box.linkPath))
        guard case .other = t.state else { Issue.record("別のものと判定されない"); return }
        #expect(t.install() != nil)
        #expect(t.uninstall() == nil)
        #expect(try String(contentsOfFile: box.linkPath, encoding: .utf8) == "mine")

        try FileManager.default.removeItem(atPath: box.linkPath)
        try FileManager.default.createSymbolicLink(atPath: box.linkPath, withDestinationPath: "/usr/bin/true")
        guard case .other = t.state else { Issue.record("別のリンクと判定されない"); return }
        #expect(t.install() != nil)
        #expect(t.uninstall() == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.linkPath) == "/usr/bin/true")
    }

    @Test("相対パスで張られたリンクも、同じ実行ファイルを指していれば installed")
    func relativeLinkCounts() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try FileManager.default.createSymbolicLink(atPath: box.linkPath, withDestinationPath: "../Apps/ShortNote.app/Contents/MacOS/ShortNote")
        #expect(tool(box).state == .installed)
    }

    @Test("安定したアプリの場所がない（swift run・隔離など）と unavailable で、入れられない")
    func unavailableWithoutAnApp() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let t = CommandLineTool(linkPath: box.linkPath, target: nil, runAsAdministrator: { _ in nil })
        #expect(t.state == .unavailable)
        #expect(t.install() != nil)
        #expect(!FileManager.default.fileExists(atPath: box.linkPath))
    }

    @Test("ディレクトリに書けないときは、管理者で実行する。コマンドは、ディレクトリを作って、上書きしない ln -s。取り消し（nil）は、エラーにしない")
    func usesAdministratorWhenNotWritable() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: box.linkDirectory.path)
        let seen = Recorder()
        let t = tool(box) { seen.add($0); return nil }
        #expect(t.install() == nil)
        #expect(seen.all == ["mkdir -p '\(box.linkDirectory.path)' && ln -s '\(box.executable)' '\(box.linkPath)'"])
        #expect(!FileManager.default.fileExists(atPath: box.linkPath))   // 管理者の実行は、この試験の代役なので、何も作られない
    }

    @Test("シェルに渡すパスは、引用符を含んでも、安全に引用される")
    func quoting() {
        #expect(CommandLineTool.shellQuote("/Applications/It's Mine.app/x") == "'/Applications/It'\\''s Mine.app/x'")
        #expect(CommandLineTool.installScript(directory: "/usr/local/bin", target: "/Applications/A B.app/Contents/MacOS/X", link: "/usr/local/bin/snote")
                == "mkdir -p '/usr/local/bin' && ln -s '/Applications/A B.app/Contents/MacOS/X' '/usr/local/bin/snote'")
    }

    @Test("別の場所の（または、もう無い）ShortNote を指すリンクは stale。付け替えられ、外せる。ShortNote ではない別のものは、stale にしない")
    func staleLinkCanBeReplacedOrRemoved() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let t = tool(box)
        let gone = "\(box.root.path)/Moved/ShortNote.app/Contents/MacOS/ShortNote"
        try FileManager.default.createSymbolicLink(atPath: box.linkPath, withDestinationPath: gone)
        #expect(t.state == .stale(gone))
        #expect(t.install() == nil)                       // 付け替え
        #expect(t.state == .installed)

        try FileManager.default.removeItem(atPath: box.linkPath)
        try FileManager.default.createSymbolicLink(atPath: box.linkPath, withDestinationPath: gone)
        #expect(t.uninstall() == nil)                      // 外す
        #expect(!FileManager.default.fileExists(atPath: box.linkPath))

        try FileManager.default.createSymbolicLink(atPath: box.linkPath, withDestinationPath: "/usr/bin/true")
        if case .stale = t.state { Issue.record("ShortNote ではないものを、stale にした") }
    }

    @Test("stale の付け替えを、管理者で実行するときは、ln -sfn（古いリンクを置き換える）。新規は、上書きしない ln -s")
    func replacingUsesForcedLinkOnlyForStale() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: box.linkDirectory.path)
        let seen = Recorder()
        let t = tool(box) { seen.add($0); return nil }
        _ = t.install()
        #expect(seen.all.last?.contains(" ln -s '") == true)
        #expect(CommandLineTool.installScript(directory: "/d", target: "/t", link: "/d/l", replacing: true) == "mkdir -p '/d' && ln -sfn '/t' '/d/l'")
    }
}
