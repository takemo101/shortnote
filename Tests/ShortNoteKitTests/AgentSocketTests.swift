import Darwin
import Foundation
import Testing
@testable import ShortNoteKit

private func started(_ result: Result<Void, AgentServer.StartError>) -> Bool {
    if case .success = result { return true }
    return false
}

private func startError(_ result: Result<Void, AgentServer.StartError>) -> AgentServer.StartError? {
    if case .failure(let error) = result { return error }
    return nil
}

/// 試験用のソケットの置き場（短いパス。`sockaddr_un` の上限に収める）。
private func tempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/snt-\(UUID().uuidString.prefix(8))", isDirectory: true)
    return url
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    return stat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

@Suite("エージェントのソケット")
struct AgentSocketTests {
    private let queue = DispatchQueue(label: "test.agent-server")

    private func server(at path: String, handler: @escaping (Data) -> String = { "echo:" + String(decoding: $0, as: UTF8.self) }) -> AgentServer {
        AgentServer(path: path, queue: queue, handler: handler)
    }

    @Test("要求を送ると、1 行の返事が返る。ディレクトリは 0700、ソケットは 0600")
    func roundTripAndPermissions() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let s = server(at: path)
        #expect(started(s.start()))
        defer { s.stop() }
        #expect(try AgentClient.send("hello", socketPath: path).get() == "echo:hello")
        #expect(mode(dir.path) == 0o700)
        #expect(mode(path) == 0o600)
    }

    @Test("要求が、何回かに分かれて届いても、改行までを 1 つの要求として読む")
    func requestInPieces() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let s = server(at: path); #expect(started(s.start())); defer { s.stop() }
        let fd = try #require(AgentSocket.connect(to: path)); defer { close(fd) }
        #expect(AgentSocket.writeAll(fd, Data("hel".utf8), timeout: 2))
        usleep(150_000)
        #expect(AgentSocket.writeAll(fd, Data("lo\n".utf8), timeout: 2))
        var buffer = [UInt8](repeating: 0, count: 64)
        var got = Data()
        let deadline = Date().addingTimeInterval(5)
        while !got.contains(0x0A), Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { continue }
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n > 0 { got.append(contentsOf: buffer[0..<n]) }
        }
        #expect(String(decoding: got, as: UTF8.self) == "echo:hello\n")
    }

    @Test("返事が {\"error\":...} なら、コードと op を持つ誤りとして返る")
    func errorReplyBecomesAnError() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let s = server(at: path) { _ in AgentError.invalid("だめ", op: 2).json }
        #expect(started(s.start())); defer { s.stop() }
        guard case .failure(let error) = AgentClient.send("x", socketPath: path) else { Issue.record("成功してしまった"); return }
        #expect(error == AgentError.invalid("だめ", op: 2) && error.exitCode == 1)
    }

    @Test("1 MiB を超える要求は、受け付けず、invalid_ops で断る。ハンドラは呼ばれない")
    func oversizedRequestIsRefused() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let calls = Counter()
        let s = server(at: path) { _ in calls.increment(); return "{}" }
        #expect(started(s.start())); defer { s.stop() }
        guard case .failure(let error) = AgentClient.send(String(repeating: "a", count: 2 << 20), socketPath: path) else { Issue.record("通ってしまった"); return }
        #expect(error.code == .invalidOps)
        #expect(calls.count == 0)
    }

    @Test("前回の異常終了で残った、応答のないソケットは、作り直す")
    func staleSocketIsReplaced() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("a.sock").path
        // 受けていないソケットのファイルを残す（bind して、閉じるだけ）
        var address = sockaddr_un()
        let filled = AgentSocket.fill(&address, path: path)
        #expect(filled)
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path) && AgentSocket.connect(to: path) == nil)

        let s = server(at: path); #expect(started(s.start())); defer { s.stop() }
        #expect(try AgentClient.send("hi", socketPath: path).get() == "echo:hi")
    }

    @Test("受けているプロセスがいるパスには、重ねて作らない（相手のソケットを消さない）")
    func liveSocketIsNotTakenOver() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let first = server(at: path); #expect(started(first.start())); defer { first.stop() }
        let second = server(at: path)
        #expect(startError(second.start()) == .alreadyServed)
        #expect(try AgentClient.send("still", socketPath: path).get() == "echo:still")
    }

    @Test("止めると、ソケットのファイルが消え、届かなくなる（unreachable、終了コード 3）")
    func stopRemovesTheSocket() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let s = server(at: path); #expect(started(s.start()))
        s.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        guard case .failure(let error) = AgentClient.send("x", socketPath: path) else { Issue.record("届いてしまった"); return }
        #expect(error.code == .unreachable && error.exitCode == 3)
    }

    @Test("起動するもの（launch）があれば、受け口ができるのを待って送る。起動できなければ unreachable")
    func launchThenSend() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let s = server(at: path)
        defer { s.stop() }
        let launched = Counter()
        let result = AgentClient.send("late", socketPath: path, launch: {
            launched.increment()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { _ = s.start() }   // アプリが起動して、受け口を開くまでの遅れ
            return true
        }, launchWait: 5)
        #expect(try result.get() == "echo:late")
        #expect(launched.count == 1)

        let none = try tempDirectory()
        let failed = AgentClient.send("x", socketPath: none.appendingPathComponent("b.sock").path, launch: { false })
        guard case .failure(let error) = failed else { Issue.record("届いてしまった"); return }
        #expect(error.code == .unreachable)
    }

    @Test("launch があっても、待つ時間のうちに受け口ができなければ unreachable")
    func launchTimesOut() throws {
        let dir = try tempDirectory()
        guard case .failure(let error) = AgentClient.send("x", socketPath: dir.appendingPathComponent("c.sock").path, launch: { true }, launchWait: 0.3) else { Issue.record("届いてしまった"); return }
        #expect(error.code == .unreachable)
    }

    @Test("パス：バンドル ID ごとに別。長すぎるときは、同じ規則で短いハッシュ名にする")
    func pathRules() {
        let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        #expect(AgentSocket.path(bundleID: "a.b", in: dir) == "/tmp/x/agent-a.b.sock")
        #expect(AgentSocket.path(bundleID: "a.c", in: dir) != AgentSocket.path(bundleID: "a.b", in: dir))
        let longDir = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 70), isDirectory: true)
        let long = AgentSocket.path(bundleID: "dev.example.some.very.long.bundle.identifier", in: longDir)
        #expect(long.utf8.count <= AgentSocket.maxPathBytes)
        #expect(long == AgentSocket.path(bundleID: "dev.example.some.very.long.bundle.identifier", in: longDir))
        #expect(long != AgentSocket.path(bundleID: "dev.example.some.very.long.bundle.identifiet", in: longDir))
    }

    @Test("長すぎて、作れないパスは、pathTooLong")
    func pathTooLong() {
        let s = AgentServer(path: "/tmp/" + String(repeating: "d", count: 120) + "/a.sock", handler: { _ in "" })
        #expect(startError(s.start()) == .pathTooLong)
    }
}

@Suite("draw・get・export・clear の引数と要求")
struct LiveCommandTests {
    private func request(_ command: String, _ args: [String], stdin: String = "") -> Result<LiveCommand.Request, AgentError> {
        LiveCommand.request(command: command, args: args, readStdin: { Data(stdin.utf8) })
    }

    @Test("get・export・clear は、引数なしの 1 語。アプリは起動しない。draw だけ起動する")
    func simpleCommands() throws {
        for name in ["get", "export", "clear"] {
            #expect(try request(name, []).get() == .init(line: name, launchesApp: false))
            guard case .failure(let error) = request(name, ["x"]) else { Issue.record("\(name) が引数を受けた"); continue }
            #expect(error.code == .usage)
        }
        let draw = try request("draw", ["-"], stdin: #"{"version":1,"ops":[{"op":"rect","x":1,"y":2,"w":3,"h":4}]}"#).get()
        #expect(draw.launchesApp && draw.line.hasPrefix("draw {"))
    }

    @Test("相対パスの画像がなければ、元のバイトをそのまま送る（改行だけ空白にする）。再エンコードで小数が 17 桁に膨らまない")
    func originalBytesAreSentWhenNoPathChanges() throws {
        let original = "{\"version\":1,\n \"ops\":[{\"op\":\"line\",\"from\":[45.7,0.1],\r\n\"to\":[1e2,12.3]},{\"op\":\"image\",\"path\":\"/abs/x.png\",\"x\":0,\"y\":0}]}"
        let line = try request("draw", ["-"], stdin: original).get().line
        let expected = "draw " + original.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        #expect(line == expected)
    }

    @Test("1 MiB 未満で、小数の多い要求（約 400 KB）は、そのまま通る（再エンコードすると 1 MiB を超えていた）")
    func decimalHeavyRequestStaysUnderTheLimit() throws {
        let points = (0..<10_000).map { _ in "[12.3,45.7]" }.joined(separator: ",")
        let pen = "{\"op\":\"pen\",\"points\":[\(points)]}"
        let doc = "{\"version\":1,\"ops\":[\(pen),\(pen),\(pen)]}"
        #expect(doc.utf8.count < 500_000)
        let line = try request("draw", ["-"], stdin: doc).get().line
        #expect(line == "draw " + doc)
        #expect(line.utf8.count - 5 <= OpsParser.maxBytes)
    }

    @Test("draw の要求は、改行のない 1 行。相対パスの画像は、CLI を呼んだ場所からの絶対パスになる")
    func drawLineIsSingleAndAbsolute() throws {
        let pretty = """
        {
          "version": 1,
          "ops": [
            {"op": "text", "x": 1, "y": 2, "text": "a\\nb"},
            {"op": "image", "path": "shots/a.png", "x": 0, "y": 0},
            {"op": "image", "path": "/abs/b.png", "x": 0, "y": 0}
          ]
        }
        """
        let line = try request("draw", ["-"], stdin: pretty).get().line
        #expect(!line.contains("\n") && line.hasPrefix("draw "))
        let body = Data(line.dropFirst("draw ".count).utf8)
        let ops = try OpsParser.parse(body).get()
        #expect(ops[0] == .text("a\nb", at: CGPoint(x: 1, y: 2), color: .black, fontSize: 18))
        let expected = URL(fileURLWithPath: "shots/a.png").standardizedFileURL.path
        #expect(expected.hasPrefix("/"))
        #expect(ops[1] == .image(path: expected, at: .zero, width: nil, height: nil))
        #expect(ops[2] == .image(path: "/abs/b.png", at: .zero, width: nil, height: nil))
    }

    @Test("draw：不正な操作は、アプリに送る前に invalid_ops。読めないファイルは io。引数の数は usage")
    func drawFailsLocally() {
        guard case .failure(let invalid) = request("draw", ["-"], stdin: #"{"version":1,"ops":[{"op":"zzz"}]}"#) else { Issue.record("通った"); return }
        #expect(invalid.code == .invalidOps && invalid.op == 0)
        guard case .failure(let missing) = request("draw", ["/no/such/ops.json"]) else { Issue.record("通った"); return }
        #expect(missing.code == .io)
        for args in [[], ["a", "b"]] {
            guard case .failure(let usage) = request("draw", args) else { Issue.record("通った"); return }
            #expect(usage.code == .usage)
        }
    }

    @Test("CLI 全体：届かないときは、標準エラーの JSON と終了コード 3。get・export・clear は、起動しない")
    func cliUnreachable() throws {
        let dir = try tempDirectory()
        let socket = dir.appendingPathComponent("none.sock").path
        let launched = Counter()
        for command in ["get", "export", "clear"] {
            #expect(AgentCLI.run([command], socketPath: socket, launch: { launched.increment(); return true }) == 3)
        }
        #expect(launched.count == 0)
        #expect(AgentCLI.run(["draw", "-"], readStdin: { Data(#"{"version":1,"ops":[{"op":"zzz"}]}"#.utf8) }, socketPath: socket, launch: { launched.increment(); return true }) == 1)
        #expect(launched.count == 0)   // 不正な操作では、アプリを起動しない
    }
}

@Suite("ソケットと画像の読み込みの、危険な入力")
struct AgentHazardTests {
    @Test("同じパスに、ソケットではないもの（利用者のファイル）があるとき、消さず、始めない")
    func nonSocketAtThePathIsLeftAlone() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("a.sock")
        try Data("my notes".utf8).write(to: path)
        let server = AgentServer(path: path.path, queue: DispatchQueue(label: "test.hazard"), handler: { _ in "" })
        guard case .failure(.system) = server.start() else { Issue.record("始めてしまった"); return }
        #expect(try String(contentsOf: path, encoding: .utf8) == "my notes")
    }

    @Test("画像の読み込みは、普通のファイルだけ（名前つきパイプ・ディレクトリ・無いパスでは、固まらず、nil）")
    func loaderRefusesNonRegularFiles() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifo = dir.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(OpsApply.loadFromDisk(fifo) == nil)
        #expect(OpsApply.loadFromDisk(dir.path) == nil)
        #expect(OpsApply.loadFromDisk(dir.appendingPathComponent("none.png").path) == nil)
    }
}
