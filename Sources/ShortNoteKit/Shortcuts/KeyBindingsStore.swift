import Foundation

/// KeyBindings の UserDefaults 永続化。保存するのは overrides のみ（JSON: コマンド名 → [KeyChord]）。
struct KeyBindingsStore {
    private let defaults: UserDefaults
    private let key: String
    private let defaultChords: [Command: [KeyChord]]

    /// `defaultChords` は、現在のキーボード配列での既定（`KeyBindings.standardDefaults`）。
    init(defaults: UserDefaults = .standard, key: String = "keyBindings", defaultChords: [Command: [KeyChord]] = KeyBindings.defaults) {
        self.defaults = defaults
        self.key = key
        self.defaultChords = defaultChords
    }

    struct Loaded: Equatable {
        var bindings: KeyBindings
        /// 読み込み時に何かを無視した場合の日本語メッセージ。
        var issue: String?
    }

    func load() -> Loaded {
        guard let data = defaults.data(forKey: key) else {
            return Loaded(bindings: KeyBindings(defaultChords: defaultChords), issue: nil)
        }
        guard let stored = try? JSONDecoder().decode([String: [KeyChord]].self, from: data) else {
            return Loaded(bindings: KeyBindings(defaultChords: defaultChords), issue: "保存されたショートカット設定を読み込めなかったため、初期設定に戻しました。")
        }

        var ignored = false
        var overrides: [Command: [KeyChord]] = [:]
        for (name, chords) in stored {
            if let command = Command(rawValue: name) { overrides[command] = chords } else { ignored = true }
        }

        // 上書きされないコマンドの既定キーは有効なままなので、それとぶつかる上書きは落とす
        // （入れ替え "1"↔"2" のように、上書きされる側の既定キーは空くので除外する）。
        // ただし、キーボードの配列に合わせて決めた既定（US の位置と違うもの）は、利用者が保存した割り当てより弱い。
        // キーボードの種類が変わっても、利用者が選んだキーが消えないように、重なるときは既定の側を外す（下で処理する）。
        let layoutDerived = Set(Command.allCases.filter { defaultChords[$0] != KeyBindings.defaults[$0] })
        var taken = Set(
            Command.allCases.filter { overrides[$0] == nil && !layoutDerived.contains($0) }.flatMap { defaultChords[$0] ?? [] }
        )
        var accepted: [Command: [KeyChord]] = [:]
        // 辞書の順序は不定なので Command.allCases 順に処理し、競合時にどちらを落とすかを決定的にする。
        for command in Command.allCases {
            guard let chords = overrides[command] else { continue }
            var kept: [KeyChord] = []
            for chord in chords {
                let invalid = KeyBindings.reservedChords.contains(chord)
                    || (command.isGlobal && !chord.isGlobalSafe)
                    || taken.contains(chord)
                if invalid { ignored = true; continue }
                taken.insert(chord)
                kept.append(chord)
            }
            // 既定と同じ内容は差分ではないので保持しない（KeyBindings の不変条件）。
            if kept != defaultChords[command] { accepted[command] = kept }
        }
        // 配列に合わせた既定が、保存した割り当てと重なるときは、既定の側を割り当てなしにする。
        var displaced: [Command] = []
        for command in Command.allCases where overrides[command] == nil && layoutDerived.contains(command) {
            if (defaultChords[command] ?? []).contains(where: { taken.contains($0) }) {
                accepted[command] = []
                displaced.append(command)
            }
        }
        var notes: [String] = []
        if ignored { notes.append("一部のショートカット設定が無効だったため無視しました。") }
        if !displaced.isEmpty {
            notes.append("キーボードの配列に合わせた既定が、保存した割り当てと重なったため、「\(displaced.map(\.title).joined(separator: "」「"))」を割り当てなしにしました。")
        }
        return Loaded(
            bindings: KeyBindings(overrides: accepted, defaultChords: defaultChords),
            issue: notes.isEmpty ? nil : notes.joined(separator: "\n")
        )
    }

    func save(_ bindings: KeyBindings) {
        guard bindings.hasCustomizations else {
            defaults.removeObject(forKey: key)
            return
        }
        let encodable = Dictionary(
            uniqueKeysWithValues: Command.allCases
                .filter { bindings.isCustomized($0) }
                .map { ($0.rawValue, bindings.chords(for: $0)) }
        )
        do {
            defaults.set(try JSONEncoder().encode(encodable), forKey: key)
        } catch {
            assertionFailure("KeyChord は常にエンコードできるはず（コードの欠陥）: \(error)")   // 利用者や環境のせいで起きる失敗ではない
        }
    }
}
