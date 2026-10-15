import AppKit
import Darwin
import Foundation

/// CLI 側。常駐中のアプリのソケットへ、1 行の要求を送り、1 行の返事を受ける（SPEC §3.7）。
enum AgentClient {
    /// アプリを起動してから、受け口を待つ長さ。
    static let launchWait: TimeInterval = 5
    /// 要求を送ってから、返事を待つ長さ。
    static let replyTimeout: TimeInterval = 10

    /// 要求を送って、返事の 1 行（改行なし）を返す。つながらなければ、`launch` があれば呼んで、`launchWait` 秒まで待つ。
    /// 返事が `{"error":...}` なら、その `AgentError`。届かなければ `unreachable`。
    static func send(_ request: String, socketPath: String, launch: (() -> Bool)? = nil, launchWait: TimeInterval = AgentClient.launchWait, replyTimeout: TimeInterval = AgentClient.replyTimeout) -> Result<String, AgentError> {
        var fd = AgentSocket.connect(to: socketPath)
        if fd == nil, let launch {
            guard launch() else { return .failure(unreachable("アプリを起動できませんでした（すでに動いていて、受け口に届かないときは、ShortNote を終了して、起動し直してください。古い版が動いているのかもしれません）", socketPath)) }
            let deadline = Date().addingTimeInterval(launchWait)
            while fd == nil, Date() < deadline {
                usleep(100_000)
                fd = AgentSocket.connect(to: socketPath)
            }
        }
        guard let fd else {
            let hint = launch == nil ? "（ShortNote が起動していないか、受け口のない古い版が動いています。`draw` は、起動していなければ起動します）" : "（\(Int(launchWait)) 秒待っても、応答がありません）"
            return .failure(unreachable("ShortNote に届きません\(hint)", socketPath))
        }
        defer { close(fd) }

        guard AgentSocket.writeAll(fd, Data((request + "\n").utf8), timeout: replyTimeout) else {
            return .failure(unreachable("要求を送れませんでした", socketPath))
        }
        guard let reply = readLine(from: fd, timeout: replyTimeout) else {
            return .failure(unreachable("返事がありません（\(Int(replyTimeout)) 秒）", socketPath))
        }
        if let error = error(in: reply) { return .failure(error) }
        return .success(reply)
    }

    private static func unreachable(_ message: String, _ path: String) -> AgentError {
        AgentError(code: .unreachable, message: "\(message)：\(path)", op: nil)
    }

    /// 返事が `{"error":{"code","message","op"?}}` なら、その誤り。
    static func error(in reply: String) -> AgentError? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
              let body = object["error"] as? [String: Any] else { return nil }
        let code = (body["code"] as? String).flatMap(AgentError.Code.init(rawValue:)) ?? .io
        return AgentError(code: code, message: body["message"] as? String ?? "(メッセージなし)", op: (body["op"] as? NSNumber)?.intValue)
    }

    private static func readLine(from fd: Int32, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 { if errno == EINTR { continue }; return nil }
            if ready == 0 { continue }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
            if count == 0 { break }   // 相手が閉じた（改行のない返事は、そこまで）
            data.append(contentsOf: chunk[0..<count])
            if data.contains(0x0A) { break }
        }
        let line = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
    }

    /// アプリを、フォーカスを奪わずに起動する（実行ファイルが `ShortNote.app` の中にあるとき）。
    /// すでに同じバンドル ID のアプリが動いているときは、起動しない（`open` は、動いているアプリに再び開く要求を送り、前面にしうる）。
    static func launchApp() -> Bool {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) { return false }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", bundle.path, "--args", AppLaunch.noActivateFlag]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// アプリの起動の引数。
enum AppLaunch {
    /// CLI（`draw`）が、アプリを起動するとき。ウィンドウは出すが、フォーカスを奪わない。
    static let noActivateFlag = "--no-activate"
}
