import Foundation

/// 常駐中のアプリに送るコマンド（`draw`・`get`・`export`・`clear`。SPEC §3.7）の、引数の処理と、要求の組み立て。
enum LiveCommand {
    static let names: Set<String> = ["draw", "get", "export", "clear"]

    /// 送る 1 行の要求。`draw` だけ、アプリが動いていなければ起動する。
    struct Request: Equatable {
        var line: String
        var launchesApp: Bool
    }

    /// `command`（`draw` など）と、その後ろの引数から、要求を作る。誤りは `usage`（引数）か、`invalid_ops`・`io`（操作の JSON）。
    static func request(command: String, args: [String], readStdin: () -> Data) -> Result<Request, AgentError> {
        switch command {
        case "draw":
            guard args.count == 1 else { return .failure(.usage("使い方：draw <操作の JSON のファイル または ->")) }
            return drawRequest(source: args[0], readStdin: readStdin)
        case "get", "export", "clear":
            guard args.isEmpty else { return .failure(.usage("`\(command)` に引数はありません：\(args.joined(separator: " "))")) }
            return .success(Request(line: command, launchesApp: false))
        default:
            return .failure(.usage("知らないサブコマンドです：\(command)"))
        }
    }

    /// 操作の JSON を検証して（不正なら、アプリに触れずに断る）、改行のない 1 行にする。
    /// 元のバイトを、そのまま送る（JSON の改行は、空白としてだけ現れるので、空白に替える）。再エンコードすると、小数が 17 桁に膨らみ、
    /// 1 MiB 未満の要求が、アプリ側の上限を超える。相対パスの画像があるときだけ、そのパスを、CLI を呼んだ場所からの絶対パスにするため、再エンコードする。
    private static func drawRequest(source: String, readStdin: () -> Data) -> Result<Request, AgentError> {
        let data: Data
        if source == "-" {
            data = readStdin()
        } else {
            guard let read = try? Data(contentsOf: URL(fileURLWithPath: source)) else { return .failure(.io("操作の JSON を読めません：\(source)")) }
            data = read
        }
        if case .failure(let error) = OpsParser.parse(data) { return .failure(error) }

        // 検証を通ったので、形は確か。
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let ops = root["ops"] as? [[String: Any]] else {
            return .failure(.invalid("JSON として読めません"))
        }
        let hasRelativeImage = ops.contains { $0["op"] as? String == "image" && !(($0["path"] as? String)?.hasPrefix("/") ?? true) }
        var body = data
        if hasRelativeImage {
            var absolute = root, absoluteOps = ops
            for i in absoluteOps.indices where absoluteOps[i]["op"] as? String == "image" {
                if let path = absoluteOps[i]["path"] as? String { absoluteOps[i]["path"] = URL(fileURLWithPath: path).standardizedFileURL.path }
            }
            absolute["ops"] = absoluteOps
            guard let encoded = try? JSONSerialization.data(withJSONObject: absolute, options: [.withoutEscapingSlashes]) else {
                return .failure(.invalid("JSON を組み立てられません"))
            }
            body = encoded
        }
        body = Data(body.map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
        guard body.count <= OpsParser.maxBytes else { return .failure(.invalid("要求が大きすぎます（1 MiB まで。画像のパスを絶対パスにしたあとの大きさ）")) }
        return .success(Request(line: "draw " + String(decoding: body, as: UTF8.self), launchesApp: true))
    }
}
