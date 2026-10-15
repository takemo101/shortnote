import CoreGraphics
import Foundation

/// 常駐中のアプリが受ける要求（1 行）を実行して、返事（1 行の JSON）を返す（SPEC §3.7）。
/// 要求は `<コマンド>` か `<コマンド> <本文>`。コマンドは `draw`（本文は操作の JSON）・`get`・`export`・`clear`。
/// 返事は、成功ならコマンドごとの JSON、失敗なら `{"error":{...}}`。
final class AgentService {
    private let canvas: AgentCanvas
    private let loadImage: (String) -> ImportedImage?

    init(canvas: AgentCanvas, loadImage: @escaping (String) -> ImportedImage? = OpsApply.loadFromDisk) {
        self.canvas = canvas
        self.loadImage = loadImage
    }

    func handle(_ request: Data) -> String {
        let space = request.firstIndex(of: 0x20)
        let command = String(decoding: space.map { request[..<$0] } ?? request[...], as: UTF8.self)
        let body = space.map { Data(request[request.index(after: $0)...]) } ?? Data()

        switch command {
        case "draw": return draw(body)
        case "get": return noBody(body, command) ?? get()
        case "export": return noBody(body, command) ?? export()
        case "clear": return noBody(body, command) ?? clear()
        default: return AgentError.usage("知らないコマンドです：\(command)").json
        }
    }

    private func noBody(_ body: Data, _ command: String) -> String? {
        body.isEmpty ? nil : AgentError.usage("`\(command)` に本文はありません").json
    }

    private func draw(_ body: Data) -> String {
        let ops: [Op]
        switch OpsParser.parse(body) {
        case .failure(let error): return error.json
        case .success(let parsed): ops = parsed
        }
        switch OpsApply.items(from: ops, canvas: canvas.agentCanvasSize, loadImage: loadImage) {
        case .failure(let error): return error.json
        case .success(let result):
            if !result.items.isEmpty { canvas.agentAppend(result.items) }   // 足すものが無ければ、取り消しの段を作らない
            return AgentJSON.line(["added": result.items.count, "clamped": result.clamped, "skipped": result.skipped])
        }
    }

    private func get() -> String {
        let snapshot = canvas.agentSnapshot()
        return AgentJSON.line([
            "canvas": ["width": ItemEncoder.number(snapshot.size.width), "height": ItemEncoder.number(snapshot.size.height)],
            "background": snapshot.background.map(ItemEncoder.rect) ?? NSNull(),
            "editing": snapshot.editing,
            "items": snapshot.items.enumerated().map { ItemEncoder.json($1, index: $0) },
        ])
    }

    private func export() -> String {
        guard let url = canvas.agentExport() else { return AgentError.io("PNG を書き出せませんでした").json }
        return AgentJSON.line(["path": url.path])
    }

    private func clear() -> String {
        AgentJSON.line(["cleared": canvas.agentClear()])
    }
}
