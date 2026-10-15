import CoreGraphics
import Foundation

/// `get` が返す、確定済みのキャンバスの内容（SPEC §3.7）。入力中の文字・ドラッグ中のものは含めない。
struct AgentSnapshot {
    /// キャンバスの大きさ（ポイント）。
    var size: CGSize
    /// 背景の画像の枠。背景がなければ `nil`。
    var background: CGRect?
    /// 人が、文字の入力か、ドラッグの途中か。
    var editing: Bool
    /// 確定済みの要素（0 が奥）。
    var items: [Item]
}

/// エージェントの操作が届く、常駐中のキャンバス。実装は、人の操作と同じ経路（`Document`・履歴・書き出しの無効化）を通す。
/// すべてメインスレッドから呼ぶ。
protocol AgentCanvas: AnyObject {
    /// キャンバスの大きさ（ポイント）。
    var agentCanvasSize: CGSize { get }
    /// 要素を、手前に足す（取り消しの 1 段）。人の入力・ドラッグは、壊さず、続く。
    func agentAppend(_ items: [Item])
    /// 確定済みの要素を消す。消すものがなければ `false`。
    func agentClear() -> Bool
    func agentSnapshot() -> AgentSnapshot
    /// 確定済みの内容の PNG のファイル。書き出せなければ `nil`。
    func agentExport() -> URL?
}
