import Darwin
import Foundation

/// 常駐中のアプリと CLI をつなぐ、Unix ドメインソケットの置き場と、接続の下回り（SPEC §3.7 の「通信と安全」）。
enum AgentSocket {
    /// `sockaddr_un.sun_path` に入る長さ（終端の NUL を除く）。
    static let maxPathBytes = 103
    /// 1 行の要求の上限。操作の JSON（1 MiB まで）に、コマンド名の分を足す。
    static let maxRequestBytes = OpsParser.maxBytes + 16

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShortNote", isDirectory: true)
    }

    /// `agent-<バンドル ID>.sock`。パスが `sockaddr_un` に入らない長さなら、バンドル ID を短いハッシュにする（両側が同じ規則で決める）。
    static func path(bundleID: String?, in directory: URL = defaultDirectory) -> String {
        let id = bundleID ?? "dev.takemo101.shortnote"
        let long = directory.appendingPathComponent("agent-\(id).sock").path
        if long.utf8.count <= maxPathBytes { return long }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return directory.appendingPathComponent("agent-\(String(hash, radix: 16)).sock").path
    }

    /// `path` に接続する。つながらなければ `nil`（相手がいない、古いソケット、など）。
    static func connect(to path: String) -> Int32? {
        var address = sockaddr_un()
        guard fill(&address, path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    static func fill(_ address: inout sockaddr_un, path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { return false }
        address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            buffer[bytes.count] = 0
        }
        return true
    }

    /// `fd` に全部書く。`timeout` 秒のうちに書けなければ `false`。
    static func writeAll(_ fd: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 { offset += written; continue }
            if written < 0 && errno == EINTR { continue }
            guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&p, 1, Int32(min(remaining, 1) * 1000))
        }
        return true
    }
}

/// 常駐中のアプリのソケット（受け口）。接続を受けて、1 行の要求ごとに `handler` を呼び、1 行の返事を書いて閉じる。
/// `handler` は `queue`（アプリでは、メインキュー）で呼ぶ。
final class AgentServer {
    enum StartError: Error, Equatable {
        case pathTooLong
        /// 同じパスで、別のプロセスが受けている。
        case alreadyServed
        case system(String)
    }

    /// 要求の途中で、これだけ待っても終わらない接続は、切る。
    static let idleTimeout: TimeInterval = 10

    private let path: String
    private let queue: DispatchQueue
    private let handler: (Data) -> String
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]

    init(path: String, queue: DispatchQueue = .main, handler: @escaping (Data) -> String) {
        self.path = path
        self.queue = queue
        self.handler = handler
    }

    /// ディレクトリ（0700）とソケット（0600）を作って、受け始める。応答のない古いソケットは、作り直す。
    func start() -> Result<Void, StartError> {
        var address = sockaddr_un()
        guard AgentSocket.fill(&address, path: path) else { return .failure(.pathTooLong) }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return .failure(.system("ディレクトリを作れません：\(directory.path)（\(error.localizedDescription)）")) }
        var info = stat()
        if stat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 != 0o700 { chmod(directory.path, 0o700) }

        if FileManager.default.fileExists(atPath: path) {
            if let live = AgentSocket.connect(to: path) { close(live); return .failure(.alreadyServed) }
            unlink(path)   // 前回の異常終了で残った、応答のないソケット
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.system("socket: \(String(cString: strerror(errno)))")) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let reason = String(cString: strerror(errno)); close(fd); return .failure(.system("bind: \(reason)")) }
        // `umask` は、プロセス全体の値なので、変えない。作った直後から 0600 でなくても、ディレクトリが 0700 なので、他のユーザーは届かない。
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let reason = String(cString: strerror(errno)); close(fd); unlink(path); return .failure(.system("listen: \(reason)")) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
        return .success(())
    }

    /// 受けるのをやめて、ソケットのファイルを消す。
    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        unlink(path)
    }

    private func acceptPending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }   // EAGAIN（もう待っている接続がない）など
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let connection = Connection(fd: fd, queue: queue, handler: handler)
            let id = ObjectIdentifier(connection)
            connection.onFinish = { [weak self] in self?.connections[id] = nil }
            connections[id] = connection
            connection.start()
        }
    }

    /// 1 つの接続。改行までを 1 つの要求として読み、返事を書いて閉じる。
    private final class Connection {
        private let fd: Int32
        private let queue: DispatchQueue
        private let handler: (Data) -> String
        private var reader: DispatchSourceRead?
        private var timer: DispatchSourceTimer?
        private var buffer = Data()
        /// 大きすぎる要求への返事を書いたあと、相手が書き終えるまで、読み捨てる（途中で閉じると、返事が届かない）。
        private var discarding = false
        private var finished = false
        var onFinish: (() -> Void)?

        init(fd: Int32, queue: DispatchQueue, handler: @escaping (Data) -> String) {
            self.fd = fd
            self.queue = queue
            self.handler = handler
        }

        func start() {
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            self.reader = reader
            reader.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + AgentServer.idleTimeout)
            timer.setEventHandler { [weak self] in self?.close() }
            self.timer = timer
            timer.resume()
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while !finished {
                let count = read(fd, &chunk, chunk.count)
                if count > 0 {
                    if discarding { continue }
                    buffer.append(contentsOf: chunk[0..<count])
                    if let newline = buffer.firstIndex(of: 0x0A) {
                        respond(to: Data(buffer[buffer.startIndex..<newline]))
                        return
                    }
                    if buffer.count > AgentSocket.maxRequestBytes {
                        buffer = Data()
                        discarding = true
                        _ = AgentSocket.writeAll(fd, Data((AgentError.invalid("要求が大きすぎます（1 MiB まで）").json + "\n").utf8), timeout: 2)
                    }
                } else if count == 0 {
                    close()   // 要求の途中で、相手が閉じた
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                    return
                }
            }
        }

        private func respond(to request: Data) {
            let reply = handler(request)
            _ = AgentSocket.writeAll(fd, Data((reply + "\n").utf8), timeout: 5)
            close()
        }

        func close() {
            guard !finished else { return }
            finished = true
            timer?.cancel(); timer = nil
            let fd = self.fd
            reader?.setCancelHandler { Darwin.close(fd) }
            reader?.cancel(); reader = nil
            onFinish?()
        }
    }
}
