import Foundation

/// エージェントからの操作（SPEC §3.7）の失敗。終了コードと `code` は SPEC のとおり。
struct AgentError: Error, Equatable {
    enum Code: String, Equatable {
        case invalidOps = "invalid_ops"
        case usage
        case unreachable
        case io
    }

    let code: Code
    let message: String
    /// 操作の問題のときだけ、何番目の操作か（0 始まり）。
    let op: Int?

    var exitCode: Int32 {
        switch code {
        case .invalidOps: return 1
        case .usage: return 2
        case .unreachable: return 3
        case .io: return 4
        }
    }

    static func invalid(_ message: String, op: Int? = nil) -> AgentError { AgentError(code: .invalidOps, message: message, op: op) }
    static func usage(_ message: String) -> AgentError { AgentError(code: .usage, message: message, op: nil) }
    static func io(_ message: String, op: Int? = nil) -> AgentError { AgentError(code: .io, message: message, op: op) }

    /// 標準エラーに出す 1 行の JSON。
    var json: String {
        var error: [String: Any] = ["code": code.rawValue, "message": message]
        if let op { error["op"] = op }
        return AgentJSON.line(["error": error])
    }
}

enum AgentJSON {
    /// キーを並べた、1 行の JSON。
    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
