import Foundation

/// ショートカットの割り当ての窓口。変更は保存し、変更を知りたい側（全域ホットキーの再登録、メニューの表示）へ知らせる。
/// キーの振り分けは `KeyRouter` が `bindings` を読んで行い、ウィンドウは、変更をここを通して行う。
final class ShortcutCenter {
    private(set) var bindings: KeyBindings
    private let store: KeyBindingsStore

    /// 保存してあった設定の一部を読み込めなかったときの理由（設定ウィンドウで知らせる）。
    let loadIssue: String?

    /// 割り当てが変わったとき、または記録中かどうかが変わったときに呼ぶ。
    var onChange: (() -> Void)?

    /// 設定ウィンドウでキーを記録している間は `true`。全域ホットキーは、記録の邪魔にならないよう、その間だけ外す。
    var isRecording = false {
        didSet { if oldValue != isRecording { onChange?() } }
    }

    /// 「ウィンドウを出す」の全域ホットキーを OS に登録できているか（他のアプリが使っていると登録できない）。
    /// 登録を行う側（`AppDelegate`）が更新し、設定ウィンドウが利用者に知らせる。
    var isGlobalKeyRegistered = true

    init(store: KeyBindingsStore = KeyBindingsStore()) {
        let loaded = store.load()
        self.store = store
        self.bindings = loaded.bindings
        self.loadIssue = loaded.issue
    }

    func chords(for command: Command) -> [KeyChord] {
        bindings.chords(for: command)
    }

    func isCustomized(_ command: Command) -> Bool {
        bindings.isCustomized(command)
    }

    /// `command` の割り当てを `chord` だけに置き換える。他のコマンドと重なる・予約済みなどのときは、理由を返して何も変えない。
    func assign(_ chord: KeyChord, to command: Command) -> Result<Void, KeyBindings.AssignError> {
        bindings.assigning(chord, to: command).map { apply($0) }
    }

    func clear(_ command: Command) { apply(bindings.clearing(command)) }

    /// `command` を初期値に戻す。初期値のキーを他のコマンドが使っているときは、理由を返して何も変えない。
    func reset(_ command: Command) -> Result<Void, KeyBindings.AssignError> {
        bindings.resetting(command).map { apply($0) }
    }


    func resetAll() { apply(bindings.resettingAll()) }

    private func apply(_ new: KeyBindings) {
        guard new != bindings else { return }
        bindings = new
        store.save(new)
        onChange?()
    }
}
