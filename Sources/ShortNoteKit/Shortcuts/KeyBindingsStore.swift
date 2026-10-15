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

        // 保存した割り当ては、上書きされないコマンドの既定より強い。利用者が選んだキーを、あとから足した既定
        // （新しいコマンドの既定や、キーボードの種類で変わる配列由来の既定）が消さないように、重なるときは既定の側を外す（下で処理する）。
        // 保存した割り当てどうしが重なるときは、Command.allCases 順の先を残す（辞書の順序は不定なので、決定的にするため）。
        var taken = Set<KeyChord>()
        var accepted: [Command: [KeyChord]] = [:]
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
        // 保存した割り当てと重なる既定を持つコマンド（保存した割り当てが無いもの）は、割り当てなしにして知らせる。
        var displaced: [Command] = []
        for command in Command.allCases where overrides[command] == nil {
            if (defaultChords[command] ?? []).contains(where: { taken.contains($0) }) {
                accepted[command] = []
                displaced.append(command)
            }
        }
        var notes: [String] = []
        if ignored { notes.append("一部のショートカット設定が無効だったため無視しました。") }
        if !displaced.isEmpty {
            notes.append("既定のキーが、保存した割り当てと重なったため、「\(displaced.map(\.title).joined(separator: "」「"))」を割り当てなしにしました。")
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
