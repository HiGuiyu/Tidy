import Foundation

/// 中文拼音转换:支持 `khj` 这类拼音首字母定位「客户A-支付网关」(§4.1 极速 fallback)
enum Pinyin {
    /// 返回 (全拼小写无空格, 每字首字母)
    static func keys(for text: String) -> (full: String, initials: String) {
        // CJK 与 ASCII 边界插空格,避免「客户A」的 A 被并进相邻音节
        var spaced = ""
        var prevCJK: Bool? = nil
        for ch in text {
            let isCJK = ch.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false
            if let p = prevCJK, p != isCJK { spaced.append(" ") }
            spaced.append(ch)
            prevCJK = isCJK
        }
        let mutable = NSMutableString(string: spaced)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let latin = (mutable as String).lowercased()
        // CFStringTransform 用空格分隔每个汉字的音节;ASCII 串保持原样
        let syllables = latin.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" })
        var initials = ""
        for s in syllables {
            if let f = s.first { initials.append(f) }
        }
        return (syllables.joined(), initials)
    }
}

/// 预计算的搜索键
struct SearchKey {
    let raw: String        // 原文小写
    let pinyinFull: String
    let initials: String

    init(_ text: String) {
        raw = text.lowercased()
        let k = Pinyin.keys(for: text)
        pinyinFull = k.full
        initials = k.initials
    }
}

enum FuzzyMatcher {
    /// 查询串对单个键打分;0 = 不匹配
    static func score(query: String, key: SearchKey) -> Double {
        let q = query.lowercased().replacingOccurrences(of: " ", with: "")
        guard !q.isEmpty else { return 0 }
        var best = 0.0
        // 1. 原文直接包含 —— 最强信号,越靠前分越高
        if let r = key.raw.range(of: q) {
            let pos = key.raw.distance(from: key.raw.startIndex, to: r.lowerBound)
            best = max(best, 100 - Double(min(pos, 30)))
        }
        // 2. 拼音首字母前缀 / 子序列
        if key.initials.hasPrefix(q) {
            best = max(best, 92)
        } else if key.initials.contains(q) {
            best = max(best, 85)
        } else if isSubsequence(q, of: key.initials) {
            best = max(best, 68)
        }
        // 3. 全拼包含 / 子序列
        if key.pinyinFull.contains(q) {
            best = max(best, 60)
        } else if isSubsequence(q, of: key.pinyinFull) {
            best = max(best, 35)
        }
        // 4. 原文子序列(容忍中间夹字)
        if best == 0, isSubsequence(q, of: key.raw) {
            best = 25
        }
        return best
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var it = needle.startIndex
        for c in haystack {
            if c == needle[it] {
                it = needle.index(after: it)
                if it == needle.endIndex { return true }
            }
        }
        return false
    }
}

/// CJK 友好的分词:ASCII 词保持完整,汉字串切成二元组(bigram),供 FTS5 unicode61 索引
enum CJKTokenizer {
    static func segment(_ text: String) -> String {
        var tokens: [String] = []
        var asciiRun = ""
        var cjkRun: [Character] = []

        func flushAscii() {
            if asciiRun.count >= 2 { tokens.append(asciiRun.lowercased()) }
            else if asciiRun.count == 1 { tokens.append(asciiRun.lowercased()) }
            asciiRun = ""
        }
        func flushCJK() {
            if cjkRun.count == 1 {
                tokens.append(String(cjkRun[0]))
            } else if cjkRun.count >= 2 {
                if cjkRun.count <= 4 { tokens.append(String(cjkRun)) }
                for i in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[i...(i+1)]))
                }
            }
            cjkRun = []
        }

        for ch in text {
            if ch.isLetter || ch.isNumber {
                if let scalar = ch.unicodeScalars.first, scalar.value >= 0x2E80 {
                    flushAscii(); cjkRun.append(ch)
                } else {
                    flushCJK(); asciiRun.append(ch)
                }
            } else {
                flushAscii(); flushCJK()
            }
        }
        flushAscii(); flushCJK()
        return tokens.joined(separator: " ")
    }

    /// 生成 FTS5 MATCH 查询:各 token 以 OR 相连,双引号防注入
    static func ftsQuery(_ text: String) -> String? {
        let tokens = segment(text).split(separator: " ").prefix(24)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " OR ")
    }
}
