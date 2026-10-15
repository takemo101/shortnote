import Foundation

/// エージェントからの操作の CLI（SPEC §3.7）。実行ファイルの最初の引数がサブコマンドのときに動く。
enum AgentCLI {
    /// いま実装しているサブコマンド。ここに無い名前は、これまでどおり、画像のパスとして扱う（アプリとして起動する）。
    static let subcommands: Set<String> = ["render"]

    static func handles(_ firstArgument: String) -> Bool { subcommands.contains(firstArgument) }

    /// 実行して、終了コードを返す。成功は標準出力に 1 行の JSON、失敗は標準エラーに 1 行の JSON。
    static func run(_ args: [String], readStdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) -> Int32 {
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
        default:
            return fail(.usage("知らないサブコマンドです：\(command)"))
        }
    }

    private static func fail(_ error: AgentError) -> Int32 {
        FileHandle.standardError.write(Data((error.json + "\n").utf8))
        return error.exitCode
    }
}
