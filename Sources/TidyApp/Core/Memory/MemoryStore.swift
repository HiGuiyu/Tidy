import Foundation
import GRDB

/// 记忆系统(§4.5)。基础层是 `~/.tidy/MEMORY.md` / `USER.md` 纯文本(人类可读可编辑),
/// GRDB + FTS5 只是它的索引与增强,双向同步。
final class MemoryStore {
    static let shared = MemoryStore()

    static var memoryFile: URL { EnvConfig.tidyDir.appendingPathComponent("MEMORY.md") }
    static var userFile: URL { EnvConfig.tidyDir.appendingPathComponent("USER.md") }

    private let db = AppDatabase.shared

    // MARK: - 基础层文件

    func ensureFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: EnvConfig.tidyDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.memoryFile.path) {
            let template = """
            # MEMORY.md — 归档规则与项目上下文

            > 每行一条规则,以 `- ` 开头。直接编辑本文件即可修改规则,App 启动时自动同步。
            > 规则示例:`- 含 invoice/发票 的 PDF → 2-Areas/财务`

            ## 归档规则

            ## 项目上下文

            """
            try? template.write(to: Self.memoryFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Self.userFile.path) {
            let template = """
            # USER.md — 用户画像

            > 工作习惯、命名偏好、层级深度偏好。每行一条,以 `- ` 开头。

            ## 偏好

            """
            try? template.write(to: Self.userFile, atomically: true, encoding: .utf8)
        }
    }

    /// 文件 → 库:把 md 里的 bullet 行导入为 semantic/procedural 记忆(按内容去重)
    func syncFromFiles() {
        syncFile(Self.memoryFile, source: "MEMORY.md", kind: "semantic")
        syncFile(Self.userFile, source: "USER.md", kind: "procedural")
    }

    private func syncFile(_ url: URL, source: String, kind: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try? db.dbQueue.write { dbx in
            // 该来源已有的内容(用于衰减判断)
            let existing = Set(try String.fetchAll(dbx, sql: "SELECT content FROM memory WHERE sourceFile = ?", arguments: [source]))
            // 全库已有的内容(用于导入去重:App 写的规则会回写到文件,不能二次导入)
            let allContents = Set(try String.fetchAll(dbx, sql: "SELECT content FROM memory WHERE decayedAt IS NULL"))
            for line in lines where !allContents.contains(line) {
                var m = Memory(id: nil, kind: kind, content: line, tokens: CJKTokenizer.segment(line),
                               scope: "global", confidence: 0.8, hitCount: 0, missCount: 0,
                               lastUsedAt: nil, supersedes: nil, condition: nil,
                               sourceFile: source, createdAt: Date(), decayedAt: nil)
                try m.insert(dbx)
            }
            // 文件中已删除的行,库里标记衰减(不物理删除,保留证据链)
            let fileSet = Set(lines)
            for content in existing where !fileSet.contains(content) {
                try dbx.execute(sql: "UPDATE memory SET decayedAt = ? WHERE sourceFile = ? AND content = ? AND decayedAt IS NULL",
                                arguments: [Date(), source, content])
            }
        }
    }

    /// 库 → 文件:新的 semantic 规则追加到 MEMORY.md「归档规则」小节
    func appendRuleToFile(_ rule: String) {
        guard var text = try? String(contentsOf: Self.memoryFile, encoding: .utf8) else { return }
        guard !text.contains("- \(rule)") else { return }
        if let range = text.range(of: "## 归档规则\n") {
            text.insert(contentsOf: "- \(rule)\n", at: range.upperBound)
        } else {
            text += "\n- \(rule)\n"
        }
        try? text.write(to: Self.memoryFile, atomically: true, encoding: .utf8)
    }

    // MARK: - 写入

    /// 情景记忆:原始事件,修正 100% 被记录(P0 验收)
    func recordEpisodic(_ content: String, scope: String = "global") {
        insert(kind: "episodic", content: content, scope: scope, confidence: 0.5, source: "db")
    }

    /// 语义规则(种子记忆 / 蒸馏产物),同时写回 MEMORY.md
    func recordSemanticRule(_ content: String, scope: String = "global") {
        // 已有相同规则则提升置信度
        let existing = try? db.dbQueue.read { dbx in
            try Memory.fetchOne(dbx, sql: "SELECT * FROM memory WHERE kind = 'semantic' AND content = ? AND decayedAt IS NULL", arguments: [content])
        }
        if let m = existing ?? nil, let id = m.id {
            try? db.dbQueue.write { dbx in
                try dbx.execute(sql: "UPDATE memory SET hitCount = hitCount + 1, confidence = MIN(0.99, confidence + 0.05), lastUsedAt = ? WHERE id = ?",
                                arguments: [Date(), id])
            }
            return
        }
        insert(kind: "semantic", content: content, scope: scope, confidence: 0.6, source: "db")
        appendRuleToFile(content)
    }

    private func insert(kind: String, content: String, scope: String, confidence: Double, source: String) {
        try? db.dbQueue.write { dbx in
            var m = Memory(id: nil, kind: kind, content: content, tokens: CJKTokenizer.segment(content),
                           scope: scope, confidence: confidence, hitCount: 0, missCount: 0,
                           lastUsedAt: nil, supersedes: nil, condition: nil,
                           sourceFile: source, createdAt: Date(), decayedAt: nil)
            try m.insert(dbx)
        }
    }

    // MARK: - 检索(FTS5 + confidence 加权,§4.5.8)

    func search(_ query: String, kinds: [String] = ["semantic", "procedural", "episodic"], limit: Int = 8) -> [Memory] {
        guard let match = CJKTokenizer.ftsQuery(query) else { return [] }
        let kindList = kinds.map { "'\($0)'" }.joined(separator: ",")
        return (try? db.dbQueue.read { dbx in
            try Memory.fetchAll(dbx, sql: """
                SELECT memory.*, bm25(memory_ft) AS rank FROM memory
                JOIN memory_ft ON memory_ft.rowid = memory.id
                WHERE memory_ft MATCH ? AND memory.kind IN (\(kindList)) AND memory.decayedAt IS NULL
                ORDER BY (bm25(memory_ft) - memory.confidence * 2.0 - MIN(memory.hitCount, 10) * 0.2) ASC
                LIMIT ?
                """, arguments: [match, limit])
        }) ?? []
    }

    /// 命中反馈:被采纳的记忆 hit+1,给出建议却被否掉的 miss+1(trust scoring)
    func feedback(hit hitIds: [Int64], miss missIds: [Int64]) {
        try? db.dbQueue.write { dbx in
            for id in hitIds {
                try dbx.execute(sql: "UPDATE memory SET hitCount = hitCount + 1, confidence = MIN(0.99, confidence + 0.03), lastUsedAt = ? WHERE id = ?",
                                arguments: [Date(), id])
            }
            for id in missIds {
                try dbx.execute(sql: "UPDATE memory SET missCount = missCount + 1, confidence = MAX(0.05, confidence - 0.05) WHERE id = ?",
                                arguments: [id])
            }
        }
    }

    /// 记忆库是否仍处于冷启动(§4.5.5)
    func isCold() -> Bool {
        let count = (try? db.dbQueue.read { dbx in
            try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM memory WHERE kind IN ('semantic','episodic') AND decayedAt IS NULL") ?? 0
        }) ?? 0
        return count < 5
    }

    /// 最近的归档决定,注入云端 prompt(hybrid 检索的一部分)
    func recentDecisions(limit: Int = 6) -> [String] {
        (try? db.dbQueue.read { dbx in
            try String.fetchAll(dbx, sql: "SELECT content FROM memory WHERE kind = 'episodic' AND decayedAt IS NULL ORDER BY id DESC LIMIT ?", arguments: [limit])
        }) ?? []
    }
}
