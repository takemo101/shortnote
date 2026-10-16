import Foundation

/// エージェントからの操作の CLI（SPEC §3.7）。実行ファイルの最初の引数がサブコマンドのときに動く。
enum AgentCLI {
    /// いま実装しているサブコマンド。ここに無い名前は、これまでどおり、画像のパスとして扱う（アプリとして起動する）。
    static let subcommands = Set(["render"]).union(LiveCommand.names)

    static func handles(_ firstArgument: String) -> Bool { subcommands.contains(firstArgument) }

    /// 実行して、終了コードを返す。成功は標準出力に 1 行の JSON、失敗は標準エラーに 1 行の JSON。
    /// `socketPath`・`launch` は、常駐中のアプリに送るコマンドが使う（試験では差し替える）。
    static func run(
        _ args: [String],
        readStdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        socketPath: String = AgentSocket.path(bundleID: Bundle.main.bundleIdentifier),
        launch: @escaping () -> Bool = AgentClient.launchApp
    ) -> Int32 {
        guard let command = args.first else { return fail(.usage("サブコマンドがありません")) }
        switch command {
        case "render":
            switch RenderCommand.parse(Array(args.dropFirst())) {
            case .failure(let error): return fail(error)
            case .success(let parsed):
                switch RenderCommand.run(parsed, readStdin: readStdin) {
                case .failure(let error): return fail(error)
                case .success(let output):
                    print(AgentJSON.line(output))
                    return 0
                }
            }
        case _ where LiveCommand.names.contains(command):
            switch LiveCommand.request(command: command, args: Array(args.dropFirst()), readStdin: readStdin) {
            case .failure(let error): return fail(error)
            case .success(let request):
                switch AgentClient.send(request.line, socketPath: socketPath, launch: request.launchesApp ? launch : nil) {
                case .failure(let error): return fail(error)
                case .success(let reply):
                    print(reply)
                    return 0
                }
            }
        default:
            return fail(.usage("知らないサブコマンドです：\(command)"))
        }
    }

    private static func fail(_ error: AgentError) -> Int32 {
        FileHandle.standardError.write(Data((error.json + "\n").utf8))
        return error.exitCode
    }
}
