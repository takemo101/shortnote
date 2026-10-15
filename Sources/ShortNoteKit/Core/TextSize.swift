import CoreGraphics

/// 文字サイズ（ポイント）。ブラシサイズとは別に、ツールバーの選択で決める。
enum TextSize {
    /// 選べる大きさ。
    static let presets: [CGFloat] = [12, 14, 18, 24, 32, 48, 64, 96]
    /// 既定の大きさ（ブラシサイズに連動していた頃の既定と同じ）。
    static let `default`: CGFloat = 18
}
