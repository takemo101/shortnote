import Foundation

/// エージェントからの操作の CLI（SPEC §3.7）。実行ファイルの最初の引数がサブコマンドのときに動く。
enum AgentCLI {
    /// いま実装しているサブコマンド。ここに無い名前は、これまでどおり、画像のパスとして扱う（アプリとして起動する）。
    /// `--help`・`-h`・`help`、`--version`・`-V`・`version` も、CLI として動く（アプリを起動しない）。
    static let helpNames: Set<String> = ["--help", "-h", "help"]
    static let versionNames: Set<String> = ["--version", "-V", "version"]
    static let subcommands = Set(["render"]).union(LiveCommand.names).union(helpNames).union(versionNames)

    static func handles(_ firstArgument: String) -> Bool { subcommands.contains(firstArgument) }

    /// 実行して、終了コードを返す。成功は標準出力に 1 行の JSON、失敗は標準エラーに 1 行の JSON。
    /// `socketPath`・`launch` は、常駐中のアプリに送るコマンドが使う（試験では差し替える）。
    static func run(
        _ args: [String],
        readStdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        socketPath: String = AgentSocket.path(bundleID: AppLocation.bundleIdentifier),
        launch: @escaping () -> Bool = AgentClient.launchApp,
        output: (String) -> Void = { print($0) },
        versionText: String = HelpText.currentVersion
    ) -> Int32 {
        guard let command = args.first else { return fail(.usage("サブコマンドがありません")) }
        if helpNames.contains(command) {
            let rest = Array(args.dropFirst())
            guard rest.count <= 1 else { return fail(.usage("使い方：help [コマンド]")) }
            guard let text = HelpText.text(for: rest.first) else { return fail(.usage("知らないコマンドです：\(rest[0])（render・draw・get・export・clear）")) }
            output(text)
            return 0
        }
        if versionNames.contains(command) {
            guard args.count == 1 else { return fail(.usage("使い方：version")) }
            output(versionText)
            return 0
        }
        if args.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }), let text = HelpText.commands[command] {
            output(text)   // `render --help` など
            return 0
        }
        switch command {
        case "render":
            switch RenderCommand.parse(Array(args.dropFirst())) {
            case .failure(let error): return fail(error)
            case .success(let parsed):
                switch RenderCommand.run(parsed, readStdin: readStdin) {
                case .failure(let error): return fail(error)
                case .success(let result):
                    output(AgentJSON.line(result))
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
                    output(reply)
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
