import Foundation

/// KeyBindings の UserDefaults 永続化。保存するのは overrides のみ（JSON: コマンド名 → [KeyChord]）。
struct KeyBindingsStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "keyBindings") {
        self.defaults = defaults
        self.key = key
    }

    struct Loaded: Equatable {
        var bindings: KeyBindings
        /// 読み込み時に何かを無視した場合の日本語メッセージ。
        var issue: String?
    }

    func load() -> Loaded {
        guard let data = defaults.data(forKey: key) else {
            return Loaded(bindings: KeyBindings(), issue: nil)
        }
        guard let stored = try? JSONDecoder().decode([String: [KeyChord]].self, from: data) else {
            return Loaded(bindings: KeyBindings(), issue: "保存されたショートカット設定を読み込めなかったため、初期設定に戻しました。")
        }

        var ignored = false
        var overrides: [Command: [KeyChord]] = [:]
        for (name, chords) in stored {
            if let command = Command(rawValue: name) { overrides[command] = chords } else { ignored = true }
        }

        // 上書きされないコマンドの既定キーは有効なままなので、それとぶつかる上書きは落とす
        // （入れ替え "1"↔"2" のように、上書きされる側の既定キーは空くので除外する）。
        var taken = Set(
            Command.allCases.filter { overrides[$0] == nil }.flatMap { KeyBindings.defaults[$0] ?? [] }
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
            if kept != KeyBindings.defaults[command] { accepted[command] = kept }
        }
        return Loaded(
            bindings: KeyBindings(overrides: accepted),
            issue: ignored ? "一部のショートカット設定が無効だったため無視しました。" : nil
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
