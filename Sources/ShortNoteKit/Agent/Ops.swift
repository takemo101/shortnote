import CoreGraphics
import Foundation

/// 色。`"#RRGGBB"` か `"#RRGGBBAA"`（sRGB）。
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }

    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit), let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        r = Double((rgb >> 16) & 0xFF) / 255
        g = Double((rgb >> 8) & 0xFF) / 255
        b = Double(rgb & 0xFF) / 255
        a = hasAlpha ? Double(value & 0xFF) / 255 : 1
    }
}

/// エージェントからの操作 1 つ（SPEC §3.7）。検証済みの値だけを持つ（`OpsParser` が作る）。
enum Op: Equatable {
    case pen(points: [CGPoint], color: RGBA, size: CGFloat)
    case line(from: CGPoint, to: CGPoint, color: RGBA, size: CGFloat)
    case ellipse(rect: CGRect, color: RGBA, size: CGFloat, fill: Bool = false)
    case rect(rect: CGRect, color: RGBA, size: CGFloat, fill: Bool = false)
    case text(String, at: CGPoint, color: RGBA, fontSize: CGFloat)
    case image(path: String, at: CGPoint, width: CGFloat?, height: CGFloat?)
}

/// 操作の JSON を、検証して `[Op]` にする。検証はここだけで行い、受け取る側は再検証しない。
/// 1 つでも不正なら、全体を断る（全部か、なしか）。
enum OpsParser {
    static let maxBytes = 1 << 20
    static let maxOps = 1000
    static let maxPenPoints = 10_000
    static let maxTextLength = 10_000
    static let maxImages = 20
    static let sizeRange: ClosedRange<Double> = 1...40
    static let fontSizeRange: ClosedRange<Double> = 8...200

    static func parse(_ data: Data) -> Result<[Op], AgentError> {
        guard data.count <= maxBytes else { return .failure(.invalid("要求が大きすぎます（1 MiB まで）")) }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return .failure(.invalid("UTF-8 の JSON でなければなりません（UTF-16 などは使えません）")) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return .failure(.invalid("JSON として読めません")) }
        guard let root = json as? [String: Any] else { return .failure(.invalid("JSON のいちばん外は、オブジェクト（{\"version\": 1, \"ops\": [...]}）でなければなりません")) }
        if let unknown = root.keys.filter({ !["version", "ops"].contains($0) }).sorted().first {
            return .failure(.invalid("知らない項目です：\(unknown)"))
        }
        guard let version = number(root["version"]), version == 1 else { return .failure(.invalid("`version` は 1 でなければなりません")) }
        guard let list = root["ops"] as? [Any] else { return .failure(.invalid("`ops` は、配列でなければなりません")) }
        guard (1...maxOps).contains(list.count) else { return .failure(.invalid("`ops` は 1〜\(maxOps) 個でなければなりません（\(list.count) 個）")) }

        var ops: [Op] = []
        var images = 0
        for (index, raw) in list.enumerated() {
            switch parseOp(raw, index: index) {
            case .failure(let error): return .failure(error)
            case .success(let op):
                if case .image = op { images += 1 }
                ops.append(op)
            }
        }
        guard images <= maxImages else { return .failure(.invalid("`image` は \(maxImages) 枚までです（\(images) 枚）")) }
        return .success(ops)
    }

    // MARK: - 1 つの操作

    private static func parseOp(_ raw: Any, index i: Int) -> Result<Op, AgentError> {
        guard let dict = raw as? [String: Any] else { return .failure(.invalid("操作は、オブジェクトでなければなりません", op: i)) }
        guard let name = dict["op"] as? String else { return .failure(.invalid("`op` がありません", op: i)) }
        let fields = Fields(dict, index: i)
        do {
            switch name {
            case "pen":
                try fields.allow(["op", "points", "color", "size"])
                guard let list = dict["points"] as? [Any] else { throw fields.fail("`points` は、[[x,y], ...] でなければなりません") }
                guard (1...maxPenPoints).contains(list.count) else { throw fields.fail("`points` は 1〜\(maxPenPoints) 点でなければなりません（\(list.count) 点）") }
                let points = try list.map { try fields.point($0, "points の要素") }
                return .success(.pen(points: points, color: try fields.color(), size: try fields.size()))
            case "line":
                try fields.allow(["op", "from", "to", "color", "size"])
                let from = try fields.point(dict["from"], "from"), to = try fields.point(dict["to"], "to")
                guard hypot(to.x - from.x, to.y - from.y) >= 1 else { throw fields.fail("直線の始点と終点が近すぎます（1 pt 以上離してください）") }
                return .success(.line(from: from, to: to, color: try fields.color(), size: try fields.size()))
            case "ellipse", "rect":
                try fields.allow(["op", "x", "y", "w", "h", "color", "size", "fill"])
                let rect = try fields.box(requireSize: true)
                let color = try fields.color(), size = try fields.size()
                var fill = false
                if let raw = dict["fill"] {
                    // 真偽値だけ（`0`・`1`・文字列は、エラー）。JSON の true/false は、CFBoolean になる。
                    guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw fields.fail("`fill` は、true か false でなければなりません") }
                    fill = flag.boolValue
                }
                return .success(name == "rect" ? .rect(rect: rect, color: color, size: size, fill: fill) : .ellipse(rect: rect, color: color, size: size, fill: fill))
            case "text":
                try fields.allow(["op", "x", "y", "text", "color", "fontSize"])
                guard let text = dict["text"] as? String else { throw fields.fail("`text` は、文字列でなければなりません") }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fields.fail("`text` が空（空白だけ）です") }
                guard text.count <= maxTextLength else { throw fields.fail("`text` は \(maxTextLength) 文字までです（\(text.count) 文字）") }
                let at = CGPoint(x: try fields.required("x"), y: try fields.required("y"))
                let fontSize = try fields.optionalNumber("fontSize", in: fontSizeRange) ?? 18
                return .success(.text(text, at: at, color: try fields.color(), fontSize: CGFloat(fontSize)))
            case "image":
                try fields.allow(["op", "path", "x", "y", "w", "h"])
                guard let path = dict["path"] as? String, !path.isEmpty else { throw fields.fail("`path` は、画像のファイルのパス（文字列）でなければなりません") }
                let at = CGPoint(x: try fields.required("x"), y: try fields.required("y"))
                let w = try fields.optionalSide("w"), h = try fields.optionalSide("h")
                return .success(.image(path: path, at: at, width: w, height: h))
            default:
                throw fields.fail("知らない `op` です：\(name)（pen・line・ellipse・rect・text・image のどれか）")
            }
        } catch let error as AgentError {
            return .failure(error)
        } catch {
            return .failure(.invalid("\(error)", op: i))
        }
    }

    /// 数値（真偽値は数値として扱わない。有限であること）。
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// 1 つの操作の項目を読む。間違いは、何番目の操作かを付けた `AgentError` にする。
    private struct Fields {
        let dict: [String: Any]
        let index: Int

        init(_ dict: [String: Any], index: Int) { self.dict = dict; self.index = index }

        func fail(_ message: String) -> AgentError { .invalid(message, op: index) }

        func allow(_ keys: Set<String>) throws {
            if let unknown = dict.keys.filter({ !keys.contains($0) }).sorted().first { throw fail("知らない項目です：\(unknown)") }
        }

        func required(_ key: String) throws -> CGFloat {
            guard let v = number(dict[key]) else { throw fail("`\(key)` は、数値でなければなりません") }
            return CGFloat(v)
        }

        func point(_ raw: Any?, _ name: String) throws -> CGPoint {
            guard let pair = raw as? [Any], pair.count == 2, let x = number(pair[0]), let y = number(pair[1]) else {
                throw fail("`\(name)` は、[x, y]（数値 2 つ）でなければなりません")
            }
            return CGPoint(x: x, y: y)
        }

        func box(requireSize: Bool) throws -> CGRect {
            let x = try required("x"), y = try required("y"), w = try required("w"), h = try required("h")
            guard w >= 1, h >= 1 else { throw fail("`w`・`h` は 1 以上でなければなりません") }
            return CGRect(x: x, y: y, width: w, height: h)
        }

        func optionalNumber(_ key: String, in range: ClosedRange<Double>) throws -> Double? {
            guard let raw = dict[key] else { return nil }
            guard let v = number(raw), range.contains(v) else { throw fail("`\(key)` は \(Int(range.lowerBound))〜\(Int(range.upperBound)) の数値でなければなりません") }
            return v
        }

        func optionalSide(_ key: String) throws -> CGFloat? {
            guard let raw = dict[key] else { return nil }
            guard let v = number(raw), v >= 1 else { throw fail("`\(key)` は 1 以上の数値でなければなりません") }
            return CGFloat(v)
        }

        func color() throws -> RGBA {
            guard let raw = dict["color"] else { return .black }
            guard let text = raw as? String, let color = RGBA(hex: text) else { throw fail("`color` は、\"#RRGGBB\" か \"#RRGGBBAA\" でなければなりません") }
            return color
        }

        func size() throws -> CGFloat { CGFloat(try optionalNumber("size", in: OpsParser.sizeRange) ?? 4) }
    }
}
