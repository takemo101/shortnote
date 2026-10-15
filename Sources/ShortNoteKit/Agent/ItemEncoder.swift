import CoreGraphics
import Foundation

/// 要素（`Item`）を、操作の JSON と同じ形にする（`get` の `items`。SPEC §3.7）。`index` は重なり順（0 が奥）。
/// 座標・大きさは、小数 3 桁に丸める（`number(_:)`）。筆圧は出さない。画像は、`path` を持たない（取り込み済みで、元のファイルは分からない）。
enum ItemEncoder {
    static func json(_ item: Item, index: Int) -> [String: Any] {
        var out: [String: Any] = ["index": index]
        switch item.content {
        case .pen(let points):
            out["op"] = "pen"
            out["points"] = points.map { [number($0.point.x), number($0.point.y)] }
            out["color"] = hex(item.color)
            out["size"] = number(item.size)
        case .line(let from, let to):
            out["op"] = "line"
            out["from"] = [number(from.x), number(from.y)]
            out["to"] = [number(to.x), number(to.y)]
            out["color"] = hex(item.color)
            out["size"] = number(item.size)
        case .ellipse(let rect), .rect(let rect):
            if case .ellipse = item.content { out["op"] = "ellipse" } else { out["op"] = "rect" }
            out["x"] = number(rect.minX); out["y"] = number(rect.minY)
            out["w"] = number(rect.width); out["h"] = number(rect.height)
            out["color"] = hex(item.color)
            out["size"] = number(item.size)
        case .text(let text, let box):
            out["op"] = "text"
            out["x"] = number(box.minX); out["y"] = number(box.minY)
            out["text"] = text
            out["color"] = hex(item.color)
            out["fontSize"] = number(item.size)
        case .image(_, let box):
            out["op"] = "image"
            out["x"] = number(box.minX); out["y"] = number(box.minY)
            out["w"] = number(box.width); out["h"] = number(box.height)
        }
        return out
    }

    /// `{"x":..,"y":..,"w":..,"h":..}`（背景の枠）。
    static func rect(_ rect: CGRect) -> [String: Any] {
        ["x": number(rect.minX), "y": number(rect.minY), "w": number(rect.width), "h": number(rect.height)]
    }

    /// 小数 3 桁に丸めた数（`-0` は `0`）。`NSDecimalNumber` なので、JSON に、丸めた桁だけが出る（`Double` のままだと、`10.3` が `10.300000000000001` と出る）。
    static func number(_ value: CGFloat) -> NSDecimalNumber {
        let rounded = (Double(value) * 1000).rounded() / 1000 + 0
        return NSDecimalNumber(string: String(format: "%.3f", rounded), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// sRGB の `"#RRGGBB"`。透明度があれば `"#RRGGBBAA"`。
    static func hex(_ color: CGColor) -> String {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let converted = srgb.flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) } ?? color
        let c = converted.components ?? [0, 0, 0, 1]
        let rgb = c.count >= 3 ? [c[0], c[1], c[2]] : [c[0], c[0], c[0]]   // 濃淡だけの色は、同じ値を 3 つ
        let alpha = converted.alpha
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        var text = "#" + rgb.map { String(format: "%02X", byte($0)) }.joined()
        if byte(alpha) != 255 { text += String(format: "%02X", byte(alpha)) }
        return text
    }
}
