import AppKit
import CoreGraphics
import Foundation

/// `render`：アプリを起動せずに、背景の画像に操作を重ねて PNG に書く（SPEC §3.7）。
enum RenderCommand {
    struct Arguments: Equatable {
        /// 背景の画像のパス。`nil` は白紙（`-`）。
        var background: String?
        /// 操作の JSON のパス。`-` は標準入力。
        var ops: String
        var output: String
        var size: CanvasSize
        var transparent: Bool
    }

    /// 引数（`render` の後ろ）を読む。誤りは `usage`。
    static func parse(_ args: [String]) -> Result<Arguments, AgentError> {
        var positional: [String] = []
        var output: String?
        var size = CanvasSize.standard
        var transparent = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o":
                guard i + 1 < args.count else { return .failure(.usage("`-o` の後ろに、出力のパスが必要です")) }
                output = args[i + 1]
                i += 1
            case "--size":
                guard i + 1 < args.count else { return .failure(.usage("`--size` の後ろに、幅x高さ（例 1280x720）が必要です")) }
                switch parseSize(args[i + 1]) {
                case .success(let s): size = s
                case .failure(let e): return .failure(e)
                }
                i += 1
            case "--transparent":
                transparent = true
            case "-":
                positional.append(arg)
            default:
                if arg.hasPrefix("-") { return .failure(.usage("知らないオプションです：\(arg)")) }
                positional.append(arg)
            }
            i += 1
        }
        guard positional.count == 2 else { return .failure(.usage("使い方：render [--size 幅x高さ] [--transparent] <背景の画像 または -> <操作の JSON または -> -o <出力.png>")) }
        guard let output else { return .failure(.usage("`-o <出力.png>` が必要です")) }
        return .success(Arguments(background: positional[0] == "-" ? nil : positional[0], ops: positional[1], output: output, size: size, transparent: transparent))
    }

    /// `幅x高さ`（ピクセル）。§3.1.1 の規則（偶数・最小・長辺の上限）で検証する。
    static func parseSize(_ text: String) -> Result<CanvasSize, AgentError> {
        let parts = text.lowercased().split(separator: "x").map(String.init)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return .failure(.usage("`--size` は 幅x高さ（例 1280x720）で指定してください：\(text)")) }
        let limits = CanvasSize.Limits(availablePoints: CGSize(width: CanvasSize.maxSide, height: CanvasSize.maxSide))
        switch CanvasSize.parse(width: w, height: h, limits: limits) {
        case .success(let size): return .success(size)
        case .failure(.belowMinimum): return .failure(.usage("小さすぎます（最小 \(CanvasSize.minimum.width)x\(CanvasSize.minimum.height)）：\(text)"))
        case .failure(.notEven): return .failure(.usage("幅と高さは偶数にしてください：\(text)"))
        case .failure(.exceedsLimits): return .failure(.usage("大きすぎます（長辺は \(CanvasSize.maxSide) まで）：\(text)"))
        }
    }

    /// 実行する。成功は、標準出力に出す内容（パスと、書いた PNG のピクセル数）。
    static func run(_ args: Arguments, readStdin: () -> Data) -> Result<[String: Any], AgentError> {
        // 操作の JSON
        let opsData: Data
        if args.ops == "-" {
            opsData = readStdin()
        } else {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: args.ops)) else { return .failure(.io("操作の JSON を読めません：\(args.ops)")) }
            opsData = data
        }
        let ops: [Op]
        switch OpsParser.parse(opsData) {
        case .success(let parsed): ops = parsed
        case .failure(let error): return .failure(error)
        }

        // キャンバス（ポイント）と背景
        let canvas = CGSize(width: args.size.width / CanvasSize.exportScale, height: args.size.height / CanvasSize.exportScale)
        var background: ImportedImage?
        var backgroundRect = CGRect.zero
        if let path = args.background {
            guard case .success(let image) = ImageIntake.image(at: URL(fileURLWithPath: path)) else { return .failure(.io("背景の画像を読めません：\(path)")) }
            background = image
            backgroundRect = Placement.fitted(image.pointSize, in: canvas)
        }

        // 操作 → 要素
        let applied: OpsResult
        switch OpsApply.items(from: ops, canvas: canvas) {
        case .success(let r): applied = r
        case .failure(let error): return .failure(error)
        }

        // 描いて、書く
        let document = Document(background: background, backgroundRect: backgroundRect, items: applied.items)
        guard let png = CanvasRenderer.pngData(document, size: canvas, transparent: args.transparent) else { return .failure(.io("PNG を作れませんでした")) }
        let url = URL(fileURLWithPath: args.output)
        do { try png.write(to: url, options: .atomic) } catch { return .failure(.io("出力を書けません：\(args.output)（\(error.localizedDescription)）")) }
        let rep = NSBitmapImageRep(data: png)
        return .success([
            "path": url.standardizedFileURL.path,
            "width": rep?.pixelsWide ?? 0,
            "height": rep?.pixelsHigh ?? 0,
            "clamped": applied.clamped,
            "skipped": applied.skipped,
        ])
    }
}
