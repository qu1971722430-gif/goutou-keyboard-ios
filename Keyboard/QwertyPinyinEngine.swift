import Foundation

/// 26 键全拼中文：字母串 → 切出可能的音节 → 查词库出候选。
///
/// 和九键（`GoutouPinyinTable.candidates(forDigits:)`）只有输入源不一样：
/// 九键拿到的是数字串，26 键直接拿到字母，所以切分时不走数字映射，直接查音节表。
/// 候选排序口径完全照抄九键那份（词优先 / 单字按全局常用度），避免两套手感不一致。
final class QwertyPinyinEngine {

    private let table: GoutouPinyinTable

    /// 已经输入、还没上屏的拼音字母。
    private(set) var letters: String = ""
    /// 尾部还没凑出完整音节的部分（打 `niha` 时的 `ha`）。
    private(set) var pending: String = ""
    private(set) var candidates: [String] = []
    private(set) var hint: String = ""

    init(table: GoutouPinyinTable = .shared) {
        self.table = table
    }

    var isComposing: Bool { !letters.isEmpty }

    /// 首选候选；没有就 nil（调用方退回"原样上屏"）。
    var primaryCandidate: String? { candidates.first }

    func input(_ text: String) {
        for scalar in text.lowercased().unicodeScalars {
            // 只吃 a-z，别把符号混进拼音
            guard scalar.value >= 97, scalar.value <= 122 else { continue }
            letters.append(Character(scalar))
        }
        refresh()
    }

    /// 回删一个拼音字母；返回 false 表示没有组字内容、该交给系统删正文。
    @discardableResult
    func deleteBackward() -> Bool {
        guard !letters.isEmpty else { return false }
        letters.removeLast()
        refresh()
        return true
    }

    func clear() {
        letters = ""
        pending = ""
        candidates = []
        hint = ""
    }

    /// 没候选 / 按了回车时的兜底：把拼音原样上屏。
    func takeLetters() -> String {
        let text = letters
        clear()
        return text
    }

    /// 选第 index 个候选；越界返回 nil 且不动状态。
    func commitCandidate(at index: Int) -> String? {
        guard index >= 0, index < candidates.count else { return nil }
        let word = candidates[index]
        clear()
        return word
    }

    // MARK: - 切分与候选

    private func refresh() {
        table.loadIfNeeded()
        var found = QwertyPinyinEngine.splitLetters(letters, syllableSet: table.syllableSet)
        pending = ""

        if found.isEmpty {
            // 整串凑不出音节：退到"最长可切前缀"，剩下的当成还没打完
            let chars = Array(letters)
            for end in stride(from: chars.count - 1, through: 1, by: -1) {
                let prefix = Array(chars[0..<end])
                let partial = QwertyPinyinEngine.splitLetters(String(prefix), syllableSet: table.syllableSet)
                if !partial.isEmpty {
                    found = partial
                    pending = String(Array(chars[end...]))
                    break
                }
            }
        }

        let full = QwertyPinyinEngine.candidates(for: found, table: table, limit: 12)
        // 首拼索引要扫整本词库，只在全拼切不完整时才去查，
        // 这样正常打 nihao 这种全拼不会每次按键都背一遍索引构建的开销。
        let needAbbr = !pending.isEmpty || full.isEmpty
        let abbr = needAbbr
            ? QwertyPinyinEngine.abbreviationCandidates(letters, table: table, limit: 8)
            : []

        if pending.isEmpty {
            // 整串能切成音节：全拼优先，首拼补在后面
            candidates = QwertyPinyinEngine.merge(primary: full, secondary: abbr, limit: 14)
        } else {
            // 切不完整（典型就是打首拼 nh / wm）：首拼结果排前面
            candidates = QwertyPinyinEngine.merge(primary: abbr, secondary: full, limit: 14)
        }
        hint = QwertyPinyinEngine.hintText(letters: letters, splits: found, pending: pending)
    }

    /// 把两组候选拼起来，去重后截断（primary 在前）。
    private static func merge(primary: [String], secondary: [String], limit: Int) -> [String] {
        var result = primary
        var seen = Set(result)
        for word in secondary where result.count < limit && !seen.contains(word) {
            seen.insert(word)
            result.append(word)
        }
        return Array(result.prefix(limit))
    }

    /// 字母串切成所有可能的音节组合（最多 maxResults 种）。
    ///
    /// `nihao` → `["ni","hao"]`；`xian` 既能是 `xian` 也能是 `xi`+`an`，两种都留。
    /// 音节最长 6 个字母（zhuang / chuang），长的优先。
    static func splitLetters(
        _ text: String,
        syllableSet: Set<String>,
        maxResults: Int = 64
    ) -> [[String]] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        var results: [[String]] = []
        var stack: [String] = []

        func walk(_ index: Int) {
            guard results.count < maxResults else { return }
            guard index < chars.count else {
                results.append(stack)
                return
            }
            var chunk = ""
            var cursor = index
            var reachable: [(end: Int, syllable: String)] = []
            while cursor < chars.count, cursor - index < 6 {
                chunk.append(chars[cursor])
                cursor += 1
                if syllableSet.contains(chunk) {
                    reachable.append((cursor, chunk))
                }
            }
            for entry in reachable.reversed() {
                stack.append(entry.syllable)
                walk(entry.end)
                stack.removeLast()
                if results.count >= maxResults { return }
            }
        }
        walk(0)
        return results
    }

    /// 切分结果 → 候选。排序口径和九键那份一致：
    /// 单音节先摆字（用户这时候要单字），多音节先摆词（这时候要「你好」）。
    static func candidates(
        for splits: [[String]],
        table: GoutouPinyinTable,
        limit: Int = 12
    ) -> [String] {
        guard !splits.isEmpty, limit > 0 else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        func add(_ items: [String]) {
            for item in items where result.count < limit && !seen.contains(item) {
                seen.insert(item)
                result.append(item)
            }
        }

        var words: [(bucket: Int, word: String)] = []
        var wordSeen = Set<String>()
        for segments in splits {
            for token in table.wordsByPinyin[segments.joined()] ?? [] {
                guard let decoded = GoutouPinyinTable.decode(token),
                      !wordSeen.contains(decoded.word) else { continue }
                wordSeen.insert(decoded.word)
                words.append(decoded)
            }
        }
        words.sort { $0.bucket > $1.bucket }

        var pool: [(secondary: Int, character: Character)] = []
        var poolSeen = Set<Character>()
        for segments in splits {
            let syllable = segments.count == 1 ? segments[0] : (segments.last ?? "")
            let groups = [
                (0, table.charsTextBySyllable[syllable] ?? ""),
                (1, table.secondaryCharsBySyllable[syllable] ?? ""),
            ]
            for (flag, text) in groups {
                for character in text where !poolSeen.contains(character) {
                    poolSeen.insert(character)
                    pool.append((flag, character))
                }
            }
        }
        pool.sort {
            $0.secondary == $1.secondary
                ? (table.charRank[$0.character] ?? Int.max) < (table.charRank[$1.character] ?? Int.max)
                : $0.secondary < $1.secondary
        }
        let poolChars = pool.map { String($0.character) }

        if (splits.first?.count ?? 0) == 1 {
            add(poolChars)
            add(words.map(\.word))
        } else {
            add(words.map(\.word))
            add(poolChars)
        }
        return result
    }

    // MARK: - 首拼（简拼）

    /// 首拼索引：`nh` → 你好、`wm` → 我们。懒构建一次，之后每次按键只查字典。
    private static var abbreviationIndex: [String: [(bucket: Int, word: String)]]?
    private static var abbreviationIndexBuilt = false

    /// 首拼候选。只在输入 ≥2 个字母时才查，避免单字母就把整本词库捞一遍。
    static func abbreviationCandidates(
        _ letters: String,
        table: GoutouPinyinTable,
        limit: Int = 8
    ) -> [String] {
        guard letters.count >= 2, letters.count <= 8 else { return [] }
        table.loadIfNeeded()
        if !abbreviationIndexBuilt {
            abbreviationIndex = buildAbbreviationIndex(table)
            abbreviationIndexBuilt = true
        }
        guard let list = abbreviationIndex?[letters] else { return [] }
        return Array(list.prefix(limit).map(\.word))
    }

    /// 遍历整本词库，把每个拼音串切成音节取首字母，做成 `首字母串 → 词` 的反查表。
    private static func buildAbbreviationIndex(
        _ table: GoutouPinyinTable
    ) -> [String: [(bucket: Int, word: String)]] {
        var index: [String: [(bucket: Int, word: String)]] = [:]
        for (pinyin, tokens) in table.wordsByPinyin {
            // 只认两个音节以上的词：单音节的首拼就是它自己，没有简的意义
            guard let abbr = abbreviation(of: pinyin, table: table), abbr.count >= 2 else { continue }
            var list: [(bucket: Int, word: String)] = []
            var seen = Set<String>()
            for token in tokens {
                guard let decoded = GoutouPinyinTable.decode(token), !seen.contains(decoded.word) else { continue }
                seen.insert(decoded.word)
                list.append(decoded)
            }
            guard !list.isEmpty else { continue }
            list.sort { $0.bucket > $1.bucket }
            var existing = index[abbr] ?? []
            existing.append(contentsOf: list.prefix(4))
            index[abbr] = existing
        }
        for (key, value) in index {
            index[key] = value.sorted { $0.bucket > $1.bucket }
        }
        return index
    }

    /// 拼音串 → 首字母串：`nihao` → `nh`、`zhongguo` → `zg`。
    private static func abbreviation(of pinyin: String, table: GoutouPinyinTable) -> String? {
        guard let first = splitLetters(pinyin, syllableSet: table.syllableSet, maxResults: 1).first,
              !first.isEmpty
        else { return nil }
        return first.map { String($0.prefix(1)) }.joined()
    }

    /// 顶部那一行：`64426 · ni'hao` 的 26 键版本（显示字母 + 切出来的拼音）。
    static func hintText(letters: String, splits: [[String]], pending: String) -> String {
        guard !letters.isEmpty else { return "" }
        guard let first = splits.first, !first.isEmpty else { return letters }
        let pinyin = first.joined(separator: "'")
        let shown = pinyin.isEmpty ? letters : "\(letters) · \(pinyin)"
        return pending.isEmpty ? shown : "\(shown) \(pending)"
    }
}
