/// 取り消し・やり直しの履歴。積む・戻す・やり直すだけを公開し、規則（上限、やり直しの破棄）をここに閉じる。
struct History<State> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    /// 取り消せる段数の上限。超えたら古い順に捨てる（長い作業でメモリが増え続けないように）。
    let limit: Int

    init(limit: Int = 200) {
        precondition(limit > 0, "履歴の上限は 1 以上")
        self.limit = limit
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 利用者の操作で状態が変わるとき、変更前の状態を積む。やり直しは捨てる。
    mutating func record(previous: State) {
        push(previous)
        redoStack.removeAll()
    }

    /// 取り消す。戻す先の状態を返し、`current` はやり直し用に積む。履歴が空なら `nil`。
    mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    /// やり直す。進む先の状態を返し、`current` は取り消し用に積む。やり直しが空なら `nil`。
    mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        push(current)
        return next
    }

    private mutating func push(_ state: State) {
        undoStack.append(state)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }
}
