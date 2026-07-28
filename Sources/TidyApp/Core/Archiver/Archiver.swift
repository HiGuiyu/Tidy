import Foundation

/// 文件系统层(§5.3):移动 + Finder 标签 + bookmark + ActionLog(可撤销,§7)
final class Archiver {
    static let shared = Archiver()
    private let db = AppDatabase.shared

    struct Result {
        let from: URL
        let to: URL
        let itemId: Int64?
    }

    enum ArchiveError: LocalizedError {
        case sourceMissing(String)
        var errorDescription: String? {
            switch self {
            case .sourceMissing(let p): return "源文件不存在:\(p)"
            }
        }
    }

    /// 归档一批文件到目标目录;newName 仅对单文件生效(保留扩展名)
    func archive(files: [URL], to dest: Destination, newBaseName: String?) throws -> [Result] {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.url, withIntermediateDirectories: true)
        var results: [Result] = []

        for (idx, src) in files.enumerated() {
            guard fm.fileExists(atPath: src.path) else { throw ArchiveError.sourceMissing(src.path) }
            var baseName = src.deletingPathExtension().lastPathComponent
            if files.count == 1, let n = newBaseName, !n.trimmingCharacters(in: .whitespaces).isEmpty {
                baseName = n.trimmingCharacters(in: .whitespaces)
            }
            let ext = src.pathExtension
            var target = dest.url.appendingPathComponent(ext.isEmpty ? baseName : "\(baseName).\(ext)")
            // 重名防冲突
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = dest.url.appendingPathComponent(ext.isEmpty ? "\(baseName) \(n)" : "\(baseName) \(n).\(ext)")
                n += 1
            }
            try fm.moveItem(at: src, to: target)

            // Finder 标签 = 语义目录名(顶层目录归档时用顶层名)
            setFinderTags([dest.leafName], for: target)

            // bookmark 跟踪外部移动(非沙盒,普通 bookmark 即可)
            let bookmark = try? target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

            var item = Item.newFile(title: target.lastPathComponent,
                                    filePath: target.path,
                                    originalPath: src.path,
                                    bookmark: bookmark)
            try? db.dbQueue.write { dbx in try item.insert(dbx) }
            db.logAction("archive", itemId: item.id, from: src.path, to: target.path)

            // 归档进项目/领域时建立关联(工作台「最近动过的文件」按 mtime 扫描,这里主要服务待办联动)
            if let itemId = item.id, dest.topCategory == "1-Projects",
               let proj = db.project(byPath: relativeTwoLevels(of: dest.relativePath)) {
                try? db.dbQueue.write { dbx in
                    try ItemProjectLink(itemId: itemId, projectId: proj.id!, relation: "primary", createdAt: Date()).insert(dbx)
                }
            }
            results.append(Result(from: src, to: target, itemId: item.id))
            _ = idx
        }
        return results
    }

    /// 撤销最近一次归档(⌥⌘Z / toast 按钮)。返回描述文本,nil 表示无可撤销。
    func undoLast() -> String? {
        guard let log = db.latestUndoableAction(), let logId = log.id else { return nil }
        let fm = FileManager.default
        let from = URL(fileURLWithPath: log.toPath)      // 现位置
        let to = URL(fileURLWithPath: log.fromPath)      // 原位置
        guard fm.fileExists(atPath: from.path) else {
            db.markUndone(logId)
            return "文件已不在归档位置,已跳过"
        }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        var target = to
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let base = to.deletingPathExtension().lastPathComponent
            let ext = to.pathExtension
            target = to.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        do {
            try fm.moveItem(at: from, to: target)
        } catch {
            return "撤销失败:\(error.localizedDescription)"
        }
        db.markUndone(logId)
        if let itemId = log.itemId {
            try? db.dbQueue.write { dbx in
                try dbx.execute(sql: "UPDATE item SET status = 'dropped', updatedAt = ? WHERE id = ?", arguments: [Date(), itemId])
            }
        }
        Telemetry.record(event: "undo", chosenPath: log.fromPath)
        MemoryStore.shared.recordEpisodic("\(Self.dateStr()) 撤销了 \(from.lastPathComponent) 的归档(原目标 \(log.toPath))")
        return "已还原 \(from.lastPathComponent)"
    }

    /// 归档失败 / 无法判断时的兜底:落入 0-Inbox(§4.1)
    func moveToInbox(files: [URL]) -> [Result] {
        let inbox = Destination(relativePath: "0-Inbox",
                                url: ParaTree.root.appendingPathComponent("0-Inbox"),
                                searchKey: SearchKey("0-Inbox"))
        return (try? archive(files: files, to: inbox, newBaseName: nil)) ?? []
    }

    // MARK: - Finder 标签

    private func setFinderTags(_ tags: [String], for url: URL) {
        let clean = tags.filter { !$0.isEmpty && !ParaTree.topDirs.contains($0) }
        guard !clean.isEmpty else { return }
        try? (url as NSURL).setResourceValue(clean as NSArray, forKey: .tagNamesKey)
    }

    private func relativeTwoLevels(of path: String) -> String {
        path.components(separatedBy: "/").prefix(2).joined(separator: "/")
    }

    static func dateStr() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
