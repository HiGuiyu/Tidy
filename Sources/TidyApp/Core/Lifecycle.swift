import Foundation

/// PARA 流转动作:项目完结/暂停、想法沉淀为资源。
/// 供工作台、复盘面板、理清面板共用。
enum ProjectLifecycle {
    /// 完结项目:status=done + 目录移入 4-Archive/YYYY-Qn/。返回新相对路径,失败返回 nil。
    @discardableResult
    static func archive(_ p: Project) -> String? {
        guard let pid = p.id else { return nil }
        let fm = FileManager.default
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        let quarter = "\(comps.year ?? 2026)-Q\(((comps.month ?? 1) - 1) / 3 + 1)"
        let archiveDir = ParaTree.root.appendingPathComponent("4-Archive/\(quarter)")
        let src = ParaTree.root.appendingPathComponent(p.path)
        var dest = archiveDir.appendingPathComponent(p.name)
        var newPath = "4-Archive/\(quarter)/\(p.name)"
        do {
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = archiveDir.appendingPathComponent("\(p.name) \(n)")
                newPath = "4-Archive/\(quarter)/\(p.name) \(n)"
                n += 1
            }
            if fm.fileExists(atPath: src.path) {
                try fm.moveItem(at: src, to: dest)
            }
        } catch {
            return nil
        }
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET status = 'done', completedAt = ?, path = ? WHERE id = ?",
                           arguments: [Date(), newPath, pid])
        }
        AppDatabase.shared.logAction("move", itemId: nil, from: src.path, to: dest.path)
        Telemetry.record(event: "project_archived", itemId: pid, chosenPath: newPath)
        MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 完结项目「\(p.name)」→ \(newPath)")
        ParaTree.shared.scan()
        return newPath
    }

    /// 重命名项目:目录与 DB 记录同步改(path 是绑定纽带)。返回新相对路径,失败 nil。
    @discardableResult
    static func rename(_ p: Project, to newName: String) -> String? {
        guard let pid = p.id else { return nil }
        let clean = newName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != p.name else { return nil }
        let fm = FileManager.default
        let src = ParaTree.root.appendingPathComponent(p.path)
        let parentRel = p.path.components(separatedBy: "/").dropLast().joined(separator: "/")
        let dest = ParaTree.root.appendingPathComponent(parentRel).appendingPathComponent(clean)
        guard !fm.fileExists(atPath: dest.path) else { return nil }
        if fm.fileExists(atPath: src.path) {
            do { try fm.moveItem(at: src, to: dest) } catch { return nil }
        } else {
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        }
        let newPath = parentRel.isEmpty ? clean : "\(parentRel)/\(clean)"
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET name = ?, path = ? WHERE id = ?",
                           arguments: [clean, newPath, pid])
        }
        AppDatabase.shared.logAction("rename", itemId: nil, from: src.path, to: dest.path)
        Telemetry.record(event: "project_renamed", itemId: pid, chosenPath: newPath)
        MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 项目「\(p.name)」重命名为「\(clean)」")
        ParaTree.shared.scan()
        return newPath
    }

    static func pause(_ p: Project) {
        guard let pid = p.id else { return }
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET status = 'paused' WHERE id = ?", arguments: [pid])
        }
        Telemetry.record(event: "project_paused", itemId: pid)
        MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 暂停项目「\(p.name)」")
    }
}

/// 想法沉淀为资源(PARA 闭环):不可执行但有长期价值的想法 → 3-Resources 里的 markdown
enum ResourceSink {
    @discardableResult
    static func sink(item: Item) -> URL? {
        guard let itemId = item.id else { return nil }
        let dir = ParaTree.root.appendingPathComponent("3-Resources/灵感笔记")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var base = item.title.prefix(40)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "想法-\(Archiver.dateStr())" }
        var url = dir.appendingPathComponent("\(base).md")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).md")
            n += 1
        }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# \(item.title)\n\n"
        md += "> 捕获于 \(f.string(from: item.createdAt))"
        if let s = item.source { md += " · 来自 \(s)" }
        md += "\n\n"
        if let c = item.content, c != item.title { md += c + "\n" }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET status = 'archived', filePath = ?, gtdList = NULL, updatedAt = ? WHERE id = ?",
                           arguments: [url.path, Date(), itemId])
        }
        Telemetry.record(event: "idea_to_resource", itemId: itemId, chosenPath: "3-Resources/灵感笔记")
        MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 想法「\(item.title.prefix(24))」沉淀为资源")
        return url
    }
}
