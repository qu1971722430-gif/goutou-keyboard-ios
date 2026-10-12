import Foundation

// 26 键全拼中文（QwertyPinyinEngine）的冒烟测试。
//
// 跑法（macOS / CI runner，不需要模拟器）：
//   swiftc -swift-version 5 Keyboard/GoutouPinyinTable.swift \
//          Keyboard/QwertyPinyinEngine.swift \
//          tools/QwertyPinyinCheck/main.swift -o /tmp/qwertypinyincheck
//   /tmp/qwertypinyincheck
//
// 覆盖：字母串切分出候选、选候选上屏、回删字母、拼不出来时原样上屏。

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func expectEqual(_ actual: String, _ expected: String, _ label: String) {
    expect(actual == expected, "\(label) → 期望「\(expected)」，实际「\(actual)」")
}

let repoChars = try? String(contentsOfFile: "Keyboard/pinyin-chars.tsv", encoding: .utf8)
let repoWords = try? String(contentsOfFile: "Keyboard/pinyin-words.tsv", encoding: .utf8)
expect(repoChars != nil && repoWords != nil, "能读到 pinyin-chars.tsv / pinyin-words.tsv")

let table = GoutouPinyinTable()
table.load(charsText: repoChars, wordsText: repoWords)
expect(table.isLoaded, "词库加载成功")
expect(table.syllableCount > 300, "音节表有货（实际 \(table.syllableCount) 个）")

let engine = QwertyPinyinEngine(table: table)

// 切分本身
let splits = QwertyPinyinEngine.splitLetters("nihao", syllableSet: table.syllableSet)
expect(splits.contains { $0 == ["ni", "hao"] }, "nihao 能切成 ni + hao")
let ambiguous = QwertyPinyinEngine.splitLetters("xian", syllableSet: table.syllableSet)
expect(ambiguous.contains { $0 == ["xian"] }, "xian 能整体成一个音节")
expect(ambiguous.contains { $0 == ["xi", "an"] }, "xian 也能切成 xi + an")

// nihao → 你好
engine.input("nihao")
expect(engine.isComposing, "输入 nihao 之后进入组字状态")
expect(engine.candidates.contains("你好"), "nihao 的候选里有「你好」")
expect(!engine.hint.isEmpty, "顶栏有提示（\(engine.hint)）")
let picked = engine.commitCandidate(at: engine.candidates.firstIndex(of: "你好") ?? -1)
expectEqual(picked ?? "", "你好", "选中「你好」返回上屏文本")
expect(!engine.isComposing, "上屏之后组字清空")
expect(engine.candidates.isEmpty, "上屏之后候选清空")

// 多音节词：zhongguo
engine.input("zhongguo")
expect(!engine.candidates.isEmpty, "zhongguo 有候选（首选 \(engine.candidates.first ?? "无")）")
engine.clear()

// 单字
engine.input("ni")
expect(engine.candidates.contains("你"), "ni 的候选里有「你」")
engine.clear()

// 回删
engine.input("nihao")
_ = engine.deleteBackward()
expectEqual(engine.letters, "niha", "回删一个字母")
expect(!engine.candidates.isEmpty, "niha 还能接着出候选（按前缀切分）")
engine.clear()

// 拼不出来 → 原样上屏
engine.input("zzzz")
expectEqual(engine.takeLetters(), "zzzz", "拼不出音节时原样上屏")
expect(!engine.isComposing, "原样上屏之后不再组字")

// 非字母不吃
engine.input("nihao1")
expectEqual(engine.letters, "nihao", "数字不会被吃进拼音")
engine.clear()

// 首拼（简拼）：nh → 你好
engine.input("nh")
expect(!engine.candidates.isEmpty, "nh 能出首拼候选（首选 \(engine.candidates.first ?? "无")）")
expect(engine.candidates.contains("你好"), "nh 的首拼候选里有「你好」")
engine.clear()

// 单字母不该捞整本词库
expect(QwertyPinyinEngine.abbreviationCandidates("n", table: table).isEmpty, "单字母不查首拼")

// 全拼能切完整时不必去扫索引，结果也不该被首拼挤掉
engine.input("nihao")
expect(engine.candidates.contains("你好"), "nihao 的候选里仍有「你好」")
engine.clear()

print("")
print(failures == 0 ? "26 键拼音：全部通过（\(checks) 项）" : "26 键拼音：\(failures) 项失败（共 \(checks) 项）")
exit(failures == 0 ? 0 : 1)
