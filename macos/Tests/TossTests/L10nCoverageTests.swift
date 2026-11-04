import Foundation
import Testing
@testable import Toss

/// 翻译表覆盖守卫：扫源码里所有 `t("…")` 的字面量键，断言每一张翻译表
/// 都覆盖全部键——新语言漏翻、调用点漏登记，这里当场红。
///
/// 扫描器是个小小的状态机（代码 / 字符串 / 插值 / 注释），因为守卫自己
/// 就吃过「被注释绊红」的亏（MenuPlacementTests 的教训），这次从根上
/// 把注释和字符串内容都剔除，只认真正的调用点。
@Suite("L10n：翻译表覆盖")
struct L10nCoverageTests {

    @Test func everyTableCoversEveryKeyInTheSources() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/TossTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // 仓库根
            .appendingPathComponent("Sources/Toss")

        let files = try FileManager.default
            .enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)?
            .allObjects
            .compactMap { $0 as? URL }
            .filter {
                $0.pathExtension == "swift"
                    // 翻译表文件是数据，不是调用点。
                    && !$0.lastPathComponent.hasPrefix("Translations+")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        #expect(!files.isEmpty, "没有扫到任何源码文件——目录结构变了？")

        var keys = Set<String>()
        var problems: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            scan(source, file: file.lastPathComponent, into: &keys, problems: &problems)
        }
        if !problems.isEmpty {
            print("L10nCoverageTests 违规清单：\n" + problems.joined(separator: "\n"))
        }
        #expect(problems.isEmpty, "调用点写法有违规——细节见测试输出")

        for (language, table) in Translations.tables.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let missing = keys.subtracting(table.keys).sorted()
            if !missing.isEmpty {
                print("\(language.rawValue) 缺 \(missing.count) 条：")
                for key in missing { print("  \(key)") }
            }
            #expect(missing.isEmpty, "\(language.rawValue) 翻译表没有覆盖全部键——细节见测试输出")
        }
    }

    // MARK: - 扫描

    private func scan(_ source: String, file: String, into keys: inout Set<String>, problems: inout [String]) {
        let chars = Array(source)
        let count = chars.count
        var i = 0
        /// 插值嵌套深度：进入 `\( ` 加一，配对 `)` 减一；大于零时字符串结束
        /// 引号不算结束（是插值里的字符串），要等深度归零再见的引号才算。
        var interpolationDepth = 0

        while i < count {
            let c = chars[i]

            if c == "/" && i + 1 < count && chars[i + 1] == "/" {
                while i < count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "\"" {
                i = skipString(chars, from: i, interpolationDepth: &interpolationDepth)
                continue
            }
            if c == "t" && i + 1 < count && chars[i + 1] == "(" && atCallBoundary(chars, i) {
                parseCall(chars, from: i + 2, file: file, line: line(of: chars, at: i), into: &keys, problems: &problems)
                i += 2
                continue
            }
            i += 1
        }
    }

    /// `t(` 前一个字符不能是标识符成员（排除 `Text(`、`Format(`、`_t(`、`.t(`……）。
    private func atCallBoundary(_ chars: [Character], _ position: Int) -> Bool {
        guard position > 0 else { return true }
        let previous = chars[position - 1]
        return !(previous.isLetter || previous.isNumber || previous == "_" || previous == ".")
    }

    private func line(of chars: [Character], at position: Int) -> Int {
        chars[..<position].filter { $0 == "\n" }.count + 1
    }

    /// 跳过一个字符串字面量，返回结束引号之后的位置。
    private func skipString(_ chars: [Character], from start: Int, interpolationDepth: inout Int) -> Int {
        var i = start + 1
        let count = chars.count
        while i < count {
            let c = chars[i]
            if c == "\\" {
                if i + 1 < count && chars[i + 1] == "(" {
                    // 插值：括号配对，内部的字符串/注释原样跳过。
                    var depth = 1
                    i += 2
                    while i < count && depth > 0 {
                        if chars[i] == "\"" {
                            var throwaway = 0
                            i = skipString(chars, from: i, interpolationDepth: &throwaway)
                            continue
                        }
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" { depth -= 1 }
                        i += 1
                    }
                    continue
                }
                i += 2
                continue
            }
            if c == "\"" { return i + 1 }
            i += 1
        }
        return count
    }

    /// 解析 `t(…)` 的参数：抽出键、挑违规。
    private func parseCall(
        _ chars: [Character], from start: Int, file: String, line: Int,
        into keys: inout Set<String>, problems: inout [String]
    ) {
        var args: [String] = []
        var depth = 1
        var argStart = start
        var i = start
        let count = chars.count

        while i < count && depth > 0 {
            let c = chars[i]
            if c == "\"" {
                i = skipString(chars, from: i, interpolationDepth: &depth)
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            if c == "," && depth == 1 {
                args.append(String(chars[argStart..<i]))
                argStart = i + 1
            }
            i += 1
        }
        args.append(String(chars[argStart..<(min(i, count))]))

        guard let first = args.first else { return }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\"") else { return } // 动态键（String(format:) 等）：直通查表，不用守

        // 键必须是单个字面量——`"a" + "b"` 拼出来的键没法在表里登记。
        if !isSingleLiteral(trimmed) {
            problems.append("\(file):\(line) 键用 + 拼接，请合并成单个字面量：\(trimmed.prefix(60))…")
            return
        }

        guard let key = decodeLiteral(trimmed) else {
            problems.append("\(file):\(line) 键里有不认识的转义：\(trimmed.prefix(60))…")
            return
        }

        // 第二个参数若还是字面量，说明旧的双参 API 又回来了。
        if args.count == 2 {
            let second = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if second.hasPrefix("\"") && second.hasSuffix("\"") && !second.contains("(") {
                problems.append("\(file):\(line) 又出现了双参字面量 t(\"…\", \"…\")——中文请进翻译表")
                return
            }
            if second.hasPrefix("context") {
                // t("Source", context: "mode") —— 键带上语境前缀。
                let parts = second.split(separator: ":", maxSplits: 1)
                if parts.count == 2,
                   let context = decodeLiteral(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    keys.insert("\(context)|\(key)")
                    return
                }
                problems.append("\(file):\(line) context 参数读不懂：\(second.prefix(40))")
                return
            }
        }

        if key.contains("\\(") {
            problems.append("\(file):\(line) 键里用了插值——插值先求值，查表永远落空；请改用 {} 模板")
            return
        }
        keys.insert(key)
    }

    /// 字面量本体之外（转义-aware 地找到收尾引号）只剩空白才算单个字面量。
    /// 字面量内部含 `+`（如 "{}+ matches"）不算拼接。
    private func isSingleLiteral(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.first == "\"" else { return false }
        var i = 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                if i + 1 < chars.count && chars[i + 1] == "(" {
                    var depth = 1
                    i += 2
                    while i < chars.count && depth > 0 {
                        if chars[i] == "\"" {
                            var throwaway = 0
                            i = skipString(chars, from: i, interpolationDepth: &throwaway)
                            continue
                        }
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" { depth -= 1 }
                        i += 1
                    }
                    continue
                }
                i += 2
                continue
            }
            if c == "\"" {
                return chars[(i + 1)...].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" }
            }
            i += 1
        }
        return false
    }

    /// 把 Swift 字面量的内部源码解码成运行时的字符串。
    private func decodeLiteral(_ literal: String) -> String? {
        guard literal.hasPrefix("\""), literal.hasSuffix("\""), literal.count >= 2 else { return nil }
        let inner = String(literal.dropFirst().dropLast())
        var result = ""
        var iterator = inner.makeIterator()
        while let c = iterator.next() {
            if c != "\\" {
                result.append(c)
                continue
            }
            guard let escape = iterator.next() else { return nil }
            switch escape {
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "u":
                // \u{XXXX}
                var hex = ""
                while let next = iterator.next() {
                    if next == "}" { break }
                    hex.append(next)
                }
                guard let scalar = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(scalar) else { return nil }
                result.append(Character(unicode))
            default: return nil
            }
        }
        return result
    }
}
