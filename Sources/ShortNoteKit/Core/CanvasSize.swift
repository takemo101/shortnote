import CoreGraphics
import Foundation

/// キャンバスの大きさ。書き出す PNG のピクセル数で表す（キャンバスのポイント数 × 書き出し倍率）。
/// 存在する値は、必ず有効（偶数・最小以上・長辺の上限以内）。作れるのは `parse` と `fitting` だけ。
struct CanvasSize: Equatable {
    let width: Int
    let height: Int

    /// 書き出しの倍率。ピクセル数 = ポイント数 × この値（Retina 相当）。
    static let exportScale = 2
    /// 書き出す PNG の長辺の上限（ピクセル）。これを超える書き出しは、倍率を下げる。
    static let maxSide = 8192

    /// 標準であり、最小でもある（キャンバスのポイント数で 480 × 320）。
    static let minimum = CanvasSize(unchecked: 960, 640)
    static let standard = minimum

    static let presets: [(title: String, size: CanvasSize)] = [
        ("960 × 640（標準）", CanvasSize(unchecked: 960, 640)),
        ("1280 × 720（HD）", CanvasSize(unchecked: 1280, 720)),
        ("1920 × 1080（Full HD）", CanvasSize(unchecked: 1920, 1080)),
        ("1080 × 1080（正方形）", CanvasSize(unchecked: 1080, 1080)),
        ("1024 × 768（4:3）", CanvasSize(unchecked: 1024, 768)),
    ]

    /// この画面で取れる最大のサイズ。幅・高さとも偶数で、長辺の上限を超えない。
    struct Limits: Equatable {
        let width: Int
        let height: Int

        /// キャンバスに使えるポイント数（画面の表示領域から、ウィンドウの枠を引いたもの）から作る。
        init(availablePoints: CGSize) {
            func evenFloor(_ points: CGFloat) -> Int {
                let px = Int((points * CGFloat(CanvasSize.exportScale)).rounded(.down))
                return max(0, min(px, CanvasSize.maxSide) / 2 * 2)
            }
            width = evenFloor(availablePoints.width)
            height = evenFloor(availablePoints.height)
        }
    }

    enum Error: Swift.Error, Equatable {
        case belowMinimum
        case notEven
        case exceedsLimits(Limits)
    }

    private init(unchecked width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    /// 入力を検証して `CanvasSize` にする。検証はここだけで行い、受け取る側は再検証しない。
    static func parse(width: Int, height: Int, limits: Limits) -> Result<CanvasSize, Error> {
        guard width >= minimum.width, height >= minimum.height else { return .failure(.belowMinimum) }
        guard width % 2 == 0, height % 2 == 0 else { return .failure(.notEven) }
        guard width <= limits.width, height <= limits.height else { return .failure(.exceedsLimits(limits)) }
        return .success(CanvasSize(unchecked: width, height))
    }

    /// `wanted` を、`limits` に収まるように縮めた有効な値。保存したサイズが今の画面に収まらないときに使う。
    /// 最小より小さい画面では最小を返す（ウィンドウ側が最小未満にはできないため）。
    static func fitting(_ wanted: CanvasSize, in limits: Limits) -> CanvasSize {
        func fit(_ value: Int, _ limit: Int, minimum: Int) -> Int {
            max(minimum, min(value, limit) / 2 * 2)
        }
        return CanvasSize(
            unchecked: fit(wanted.width, limits.width, minimum: minimum.width),
            fit(wanted.height, limits.height, minimum: minimum.height)
        )
    }

    /// キャンバスのポイント数。
    var points: CGSize {
        CGSize(width: CGFloat(width) / CGFloat(Self.exportScale), height: CGFloat(height) / CGFloat(Self.exportScale))
    }
}

/// キャンバスのサイズの保存（`UserDefaults`）。保存するのはこの 2 項目だけ。
struct CanvasSizeStore {
    private let defaults: UserDefaults
    private static let widthKey = "canvasWidthPx"
    private static let heightKey = "canvasHeightPx"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 保存してあるサイズ。無い・壊れている（最小未満・奇数・長辺の上限超）なら標準。
    /// 画面に収まるかは、ここでは見ない（`CanvasSize.fitting` で、使う側が画面に合わせる）。
    func load() -> CanvasSize {
        let w = defaults.integer(forKey: Self.widthKey), h = defaults.integer(forKey: Self.heightKey)
        let wide = CanvasSize.Limits(availablePoints: CGSize(width: CGFloat(CanvasSize.maxSide), height: CGFloat(CanvasSize.maxSide)))
        if case .success(let size) = CanvasSize.parse(width: w, height: h, limits: wide) { return size }
        return .standard
    }

    func save(_ size: CanvasSize) {
        defaults.set(size.width, forKey: Self.widthKey)
        defaults.set(size.height, forKey: Self.heightKey)
    }
}
