import CoreGraphics
import Foundation

/// ツールのパレットの置き場所と向き（SPEC §4）：キャンバスの上に横並び（既定）、左に縦並び、右に縦並び。
/// 利用者が、パレットをドラッグして動かす。離した所に近い縁に、くっつく。
enum PaletteOrientation: String, CaseIterable {
    case top
    case left
    case right

    /// 縦並びか（左・右）。
    var isVertical: Bool { self != .top }
}

/// パレットの置き場所の決め方（座標はすべて、左上が原点の、窓の内容の中の値）。
enum PaletteDock {
    /// いまの置き場所に、ポインタの近さを、この分だけ有利にする（pt）。縦並びのつまみは、窓の上端の近くにあるので、
    /// 近さだけで決めると、つまみを持っただけで「上」に変わってしまう。別の縁へ移すには、その縁のほうへ、はっきり動かす。
    static let stickiness: CGFloat = 60

    /// ポインタ `pointer` の置き場所：いちばん近い縁（上・左・右）。ただし、`current`（いまの置き場所）は、`stickiness` だけ近いものとして数える。距離が同じなら、上を先にする。
    static func orientation(forPointer pointer: CGPoint, in size: CGSize, current: PaletteOrientation) -> PaletteOrientation {
        func distance(_ edge: PaletteOrientation, _ raw: CGFloat) -> CGFloat { edge == current ? raw - stickiness : raw }
        let top = distance(.top, pointer.y), left = distance(.left, pointer.x), right = distance(.right, size.width - pointer.x)
        if top <= left && top <= right { return .top }
        return left <= right ? .left : .right
    }

    /// パレットの、縁に沿った位置（縁の端からの距離。0 以上）。パレットを持った所（始まりから `grab`）が、ポインタの縁に沿った位置に来るようにして、
    /// 縁の内側に収める。`track` は、縁に沿った、使える長さ。`palette` は、縁に沿った、パレットの長さ。`start` は、縁に沿った、使える範囲の始まり。
    static func offset(pointerAlongEdge: CGFloat, grab: CGFloat, palette: CGFloat, start: CGFloat, track: CGFloat) -> CGFloat {
        let slack = max(track - palette, 0)
        return min(max(pointerAlongEdge - grab - start, 0), slack)
    }
}

/// パレットの置き場所の保存（`UserDefaults`）。保存するのは、置き場所と、縁に沿った位置の 2 項目だけ。
struct PaletteOrientationStore {
    private let defaults: UserDefaults
    static let key = "paletteOrientation"
    static let offsetKey = "paletteOffset"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 保存してある置き場所。無い・読めない値なら、上（横並び）。
    func load() -> PaletteOrientation {
        defaults.string(forKey: Self.key).flatMap(PaletteOrientation.init(rawValue:)) ?? .top
    }

    /// 保存してある、縁に沿った位置（pt。0 以上）。無い・負・有限でない値なら 0（縁の端）。
    func loadOffset() -> CGFloat {
        let value = defaults.double(forKey: Self.offsetKey)
        return value.isFinite && value > 0 ? CGFloat(value) : 0
    }

    func save(_ orientation: PaletteOrientation, offset: CGFloat) {
        defaults.set(orientation.rawValue, forKey: Self.key)
        defaults.set(Double(offset), forKey: Self.offsetKey)
    }
}
