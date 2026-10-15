import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ShortNoteKit

@Suite("render コマンド")
struct RenderCommandTests {
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shortnote-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

    /// 単色の PNG ファイル（点で 480×320 pt ＝ 960×640 px・144 dpi）。
    private func writeSolidPNG(to url: URL, red: CGFloat, green: CGFloat, blue: CGFloat) throws {
        let ctx = try #require(CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    // MARK: - 引数

    @Test("引数の読み方")
    func parsesArguments() throws {
        let a = try RenderCommand.parse(["bg.png", "ops.json", "-o", "out.png"]).get()
        #expect(a == .init(background: "bg.png", ops: "ops.json", output: "out.png", size: .standard, transparent: false))
        let c = try RenderCommand.parse(["-o", "o.png", "--size", "1280X720", "--transparent", "-", "ops.json"]).get()
        #expect(c.background == nil)
        let d = try RenderCommand.parse(["-", "-", "-o", "o.png"]).get()      // 白紙の背景に、標準入力の操作（エージェントの典型の使い方）
        #expect(d.background == nil && d.ops == "-")
        #expect(c.size.width == 1280 && c.size.height == 720)
        #expect(c.transparent)
    }

    @Test("引数の誤りは usage（終了コード 2）", arguments: [
        [], ["a.png"], ["a.png", "ops.json"], ["a.png", "ops.json", "-o"], ["a.png", "ops.json", "x.png", "-o", "o.png"],
        ["a.png", "ops.json", "-o", "o.png", "--bogus"], ["a.png", "ops.json", "-o", "o.png", "--size"],
        ["a.png", "ops.json", "-o", "o.png", "--size", "big"],
    ])
    func rejectsBadArguments(args: [String]) {
        guard case .failure(let error) = RenderCommand.parse(args) else { Issue.record("通ってしまった：\(args)"); return }
        #expect(error.code == .usage)
        #expect(error.exitCode == 2)
    }

    @Test("--size：偶数・最小・長辺の上限（§3.1.1）", arguments: [
        ("960x640", true), ("1280x720", true), ("8192x1000", true),
        ("958x640", false), ("961x640", false), ("100x100", false), ("8194x1000", false), ("1280", false), ("axb", false),
    ])
    func sizeRules(text: String, valid: Bool) {
        if case .success = RenderCommand.parseSize(text) { #expect(valid, "\(text)") } else { #expect(!valid, "\(text)") }
    }

    // MARK: - 実行

    @Test("白紙に操作を重ねた PNG を書く：標準の大きさは 960×640 px。位置と色が合う")
    func rendersOntoABlankCanvas() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let ops = dir.appendingPathComponent("ops.json"), out = dir.appendingPathComponent("out.png")
        try write(##"{"version":1,"ops":[{"op":"rect","x":100,"y":100,"w":100,"h":60,"color":"#ff0000","size":6}]}"##, to: ops)
        let args = try RenderCommand.parse(["-", ops.path, "-o", out.path]).get()
        let result = try RenderCommand.run(args, readStdin: { Data() }).get()

        #expect(result["width"] as? Int == 960)
        #expect(result["height"] as? Int == 640)
        #expect(result["path"] as? String == out.standardizedFileURL.path)
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: out)))
        let edge = pixel(rep, 200, 240)           // 四角の左の辺（x=100 pt、y=120 pt の 2 倍）
        #expect(edge.r > 0.9 && edge.g < 0.4 && edge.b < 0.2, "edge=\(edge)")
        let inside = pixel(rep, 300, 240), outside = pixel(rep, 100, 100)
        #expect(inside.r > 0.99 && inside.g > 0.99 && inside.b > 0.99)
        #expect(outside.r > 0.99 && outside.g > 0.99 && outside.b > 0.99)
    }

    @Test("--size と --transparent：ピクセル数がサイズどおりで、背景が透明になる")
    func sizeAndTransparency() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let ops = dir.appendingPathComponent("ops.json"), out = dir.appendingPathComponent("out.png")
        try write(#"{"version":1,"ops":[{"op":"line","from":[10,10],"to":[100,10]}]}"#, to: ops)
        let args = try RenderCommand.parse(["--size", "1280x720", "--transparent", "-", ops.path, "-o", out.path]).get()
        let result = try RenderCommand.run(args, readStdin: { Data() }).get()
        #expect(result["width"] as? Int == 1280 && result["height"] as? Int == 720)
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: out)))
        #expect(pixel(rep, 1000, 600).a == 0)
    }

    @Test("背景の画像：キャンバスに収まる位置に置かれ、操作がその上に重なる。操作は標準入力からも読める")
    func backgroundImageAndStdin() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bg = dir.appendingPathComponent("bg.png"), out = dir.appendingPathComponent("out.png")
        try writeSolidPNG(to: bg, red: 0, green: 0.8, blue: 0.85)
        let json = Data(##"{"version":1,"ops":[{"op":"ellipse","x":20,"y":20,"w":100,"h":60,"color":"#000000","size":6}]}"##.utf8)
        let args = try RenderCommand.parse([bg.path, "-", "-o", out.path]).get()
        _ = try RenderCommand.run(args, readStdin: { json }).get()
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: out)))
        let teal = pixel(rep, 800, 500), ring = pixel(rep, 40, 100)   // 楕円の左端（x=20 pt、y=50 pt の 2 倍）
        #expect(teal.r < 0.2 && teal.g > 0.6 && teal.b > 0.6, "背景が出ていない：\(teal)")
        #expect(ring.r < 0.2 && ring.g < 0.2 && ring.b < 0.2, "楕円が出ていない：\(ring)")
    }

    @Test("範囲外の座標は、エラーにならず、結果に clamped が出る")
    func clampedIsReported() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.png")
        let args = RenderCommand.Arguments(background: nil, ops: "-", output: out.path, size: .standard, transparent: false)
        let json = Data(#"{"version":1,"ops":[{"op":"line","from":[10,10],"to":[5000,10]},{"op":"rect","x":900,"y":900,"w":10,"h":10}]}"#.utf8)
        let result = try RenderCommand.run(args, readStdin: { json }).get()
        #expect(result["clamped"] as? [Int] == [0, 1])
        #expect(result["skipped"] as? [Int] == [1])
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test("不正な操作の JSON は、出力のファイルを作らない（全部か、なしか）")
    func invalidOpsWriteNothing() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.png")
        let args = RenderCommand.Arguments(background: nil, ops: "-", output: out.path, size: .standard, transparent: false)
        let json = Data(#"{"version":1,"ops":[{"op":"line","from":[10,10],"to":[50,10]},{"op":"nope"}]}"#.utf8)
        guard case .failure(let error) = RenderCommand.run(args, readStdin: { json }) else { Issue.record("通ってしまった"); return }
        #expect(error.code == .invalidOps && error.op == 1)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("読めない入力・書けない出力は io（終了コード 4）")
    func ioFailures() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let json = Data(#"{"version":1,"ops":[{"op":"line","from":[10,10],"to":[50,10]}]}"#.utf8)
        let cases: [RenderCommand.Arguments] = [
            .init(background: nil, ops: dir.appendingPathComponent("missing.json").path, output: dir.appendingPathComponent("o.png").path, size: .standard, transparent: false),
            .init(background: dir.appendingPathComponent("missing.png").path, ops: "-", output: dir.appendingPathComponent("o.png").path, size: .standard, transparent: false),
            .init(background: nil, ops: "-", output: dir.appendingPathComponent("no-such-dir/o.png").path, size: .standard, transparent: false),
        ]
        for args in cases {
            guard case .failure(let error) = RenderCommand.run(args, readStdin: { json }) else { Issue.record("通ってしまった：\(args)"); continue }
            #expect(error.code == .io && error.exitCode == 4, "\(args)")
        }
    }

    @Test("CLI：render だけがサブコマンド。ほかの名前と、画像のパスは、アプリの起動のまま")
    func subcommandDetection() {
        #expect(AgentCLI.handles("render"))
        for other in ["draw", "get", "export", "clear", "./render", "/tmp/render.png", "image.png", "-psn_0_1"] { #expect(!AgentCLI.handles(other), "\(other)") }
    }

    @Test("CLI：終了コード（誤った使い方は 2、成功は 0、不正な JSON は 1）")
    func exitCodes() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("o.png")
        #expect(AgentCLI.run(["render"]) == 2)
        #expect(AgentCLI.run(["render", "-", "-", "-o", out.path], readStdin: { Data("not json".utf8) }) == 1)   // 標準入力の操作が JSON でない
        #expect(AgentCLI.run(["render", "-", dir.appendingPathComponent("none.json").path, "-o", out.path]) == 4)
        let ops = dir.appendingPathComponent("ops.json")
        try write(#"{"version":1,"ops":[{"op":"pen","points":[[10,10],[50,50]]}]}"#, to: ops)
        #expect(AgentCLI.run(["render", "-", ops.path, "-o", out.path]) == 0)
        try write(#"{"version":1,"ops":[{"op":"bogus"}]}"#, to: ops)
        #expect(AgentCLI.run(["render", "-", ops.path, "-o", dir.appendingPathComponent("o2.png").path]) == 1)
    }
}
