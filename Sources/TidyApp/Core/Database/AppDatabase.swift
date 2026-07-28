import Foundation
import GRDB

/// GRDB 本地库(§5.3):~/.tidy/tidy.sqlite
final class AppDatabase {
    static let shared = try! AppDatabase()

    let dbQueue: DatabaseQueue

    private init() throws {
        let dir = EnvConfig.tidyDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("tidy.sqlite").path)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("dueDate", .datetime)
                t.column("lastWorkedAt", .datetime)
                t.column("lastProgressNote", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(table: "area") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("reviewCadence", .text)
            }
            try db.create(table: "item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content", .text)
                t.column("summary", .text)
                t.column("status", .text).notNull()
                t.column("isActionable", .boolean).notNull().defaults(to: false)
                t.column("nextAction", .text)
                t.column("importance", .integer)
                t.column("urgency", .integer)
                t.column("dueDate", .datetime)
                t.column("filePath", .text)
                t.column("originalPath", .text)
                t.column("bookmarkData", .blob)
                t.column("source", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(table: "itemProjectLink") { t in
                t.column("itemId", .integer).notNull().references("item", onDelete: .cascade)
                t.column("projectId", .integer).notNull().references("project", onDelete: .cascade)
                t.column("relation", .text).notNull().defaults(to: "primary")
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["itemId", "projectId"])
            }
            try db.create(table: "memory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("content", .text).notNull()
                t.column("tokens", .text).notNull()
                t.column("scope", .text).notNull().defaults(to: "global")
                t.column("confidence", .double).notNull().defaults(to: 0.5)
                t.column("hitCount", .integer).notNull().defaults(to: 0)
                t.column("missCount", .integer).notNull().defaults(to: 0)
                t.column("lastUsedAt", .datetime)
                t.column("supersedes", .integer)
                t.column("condition", .text)
                t.column("sourceFile", .text).notNull().defaults(to: "db")
                t.column("createdAt", .datetime).notNull()
                t.column("decayedAt", .datetime)
            }
            // FTS5 全文检索(§4.5.8),外部内容表 + 自动同步
            try db.create(virtualTable: "memory_ft", using: FTS5()) { t in
                t.synchronize(withTable: "memory")
                t.tokenizer = .unicode61()
                t.column("tokens")
            }
            try db.create(table: "skill") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("trigger", .text).notNull()
                t.column("steps", .text).notNull()
                t.column("observedCount", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull().defaults(to: "suggested")
                t.column("lastRunAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "memoryDistillRun") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("depth", .integer).notNull()
                t.column("trigger", .text).notNull()
                t.column("inputEpisodicIds", .text).notNull()
                t.column("producedIds", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
            try db.create(table: "actionLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("action", .text).notNull()
                t.column("itemId", .integer)
                t.column("fromPath", .text).notNull()
                t.column("toPath", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("undone", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "focusSession") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("projectId", .integer).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("progressNote", .text)
            }
            try db.create(table: "telemetry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("event", .text).notNull()
                t.column("itemId", .integer)
                t.column("suggestedPaths", .text).notNull().defaults(to: "[]")
                t.column("suggestedScores", .text).notNull().defaults(to: "[]")
                t.column("chosenPath", .text)
                t.column("chosenRank", .integer)
                t.column("latencyMs", .integer)
                t.column("usedCloud", .boolean).notNull().defaults(to: false)
                t.column("modelTier", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-gtd") { db in
            try db.alter(table: "item") { t in
                t.add(column: "gtdList", .text)          // action | waiting | someday
                t.add(column: "expectedOutcome", .text)  // 任务 = 行动 + 期望结果
                t.add(column: "remindAt", .datetime)     // 时间提及 → 提醒标记
                t.add(column: "seq", .integer)           // 计划步骤序号
                t.add(column: "waitingFor", .text)       // 等待:等谁/等什么
            }
            try db.alter(table: "project") { t in
                t.add(column: "purpose", .text)          // 自然计划法:目的
                t.add(column: "outcome", .text)          // 自然计划法:期望结果
            }
            // 存量已理清行动归入行动清单
            try db.execute(sql: "UPDATE item SET gtdList = 'action' WHERE status = 'clarified' AND isActionable = 1")
        }
        migrator.registerMigration("v3-reminded") { db in
            // 提醒弹出时间:与 remindAt 分离,触发后仍保留逾期显示,且不重复弹
            try db.alter(table: "item") { t in
                t.add(column: "remindedAt", .datetime)
            }
        }
        return migrator
    }

    // MARK: - Project / Area 自动登记(零手工维护:目录即真相源)

    /// 目录扫描结果 upsert 进库;已存在(按 path)则跳过
    func registerScanned(projects: [(name: String, path: String)], areas: [(name: String, path: String)]) {
        try? dbQueue.write { db in
            for p in projects {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM project WHERE path = ?)", arguments: [p.path]) ?? false
                if !exists {
                    var proj = Project(id: nil, name: p.name, path: p.path, status: "active",
                                       dueDate: nil, lastWorkedAt: nil, lastProgressNote: nil,
                                       purpose: nil, outcome: nil, createdAt: Date(), completedAt: nil)
                    try proj.insert(db)
                }
            }
            for a in areas {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM area WHERE path = ?)", arguments: [a.path]) ?? false
                if !exists {
                    var area = Area(id: nil, name: a.name, path: a.path, reviewCadence: nil)
                    try area.insert(db)
                }
            }
        }
    }

    func activeProjects() -> [Project] {
        (try? dbQueue.read { db in
            try Project.fetchAll(db, sql: "SELECT * FROM project WHERE status = 'active' ORDER BY lastWorkedAt DESC NULLS LAST, createdAt DESC")
        }) ?? []
    }

    func project(byPath path: String) -> Project? {
        try? dbQueue.read { db in
            try Project.fetchOne(db, sql: "SELECT * FROM project WHERE path = ?", arguments: [path])
        }
    }

    func project(byId id: Int64) -> Project? {
        try? dbQueue.read { db in
            try Project.fetchOne(db, sql: "SELECT * FROM project WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - 工作台聚合查询(§4.3,100% 自动聚合)

    func nextActions(projectId: Int64, limit: Int = 3) -> [Item] {
        (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT item.* FROM item
                JOIN itemProjectLink l ON l.itemId = item.id
                WHERE l.projectId = ? AND item.nextAction IS NOT NULL
                  AND item.status IN ('inbox','clarified')
                ORDER BY item.urgency DESC NULLS LAST, item.importance DESC NULLS LAST, item.createdAt DESC
                LIMIT ?
                """, arguments: [projectId, limit])
        }) ?? []
    }

    func unprocessedCaptures(projectId: Int64, limit: Int = 5) -> [Item] {
        (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT item.* FROM item
                JOIN itemProjectLink l ON l.itemId = item.id
                WHERE l.projectId = ? AND item.type IN ('idea','link') AND item.status = 'inbox'
                ORDER BY item.createdAt DESC LIMIT ?
                """, arguments: [projectId, limit])
        }) ?? []
    }

    func inboxCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status = 'inbox'") ?? 0
        }) ?? 0
    }

    // MARK: - GTD:理清 / 执行(§4.4)

    /// 收件箱里待理清的想法/链接
    func inboxCaptures(limit: Int = 100) -> [Item] {
        (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT * FROM item WHERE type IN ('idea','link') AND status = 'inbox'
                ORDER BY createdAt ASC LIMIT ?
                """, arguments: [limit])
        }) ?? []
    }

    /// 已理清、可执行、未完成的行动(艾森豪威尔矩阵数据源)
    func actionableOpen(limit: Int = 40) -> [Item] {
        (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT * FROM item WHERE isActionable = 1 AND status = 'clarified'
                  AND (gtdList IS NULL OR gtdList = 'action')
                ORDER BY urgency DESC NULLS LAST, importance DESC NULLS LAST, seq ASC NULLS LAST, createdAt ASC LIMIT ?
                """, arguments: [limit])
        }) ?? []
    }

    // MARK: - 四清单(行动 / 等待 / 搁置 / 已完成)

    func items(inList list: String, limit: Int = 100) -> [Item] {
        (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT * FROM item WHERE status = 'clarified' AND gtdList = ?
                ORDER BY remindAt ASC NULLS LAST, urgency DESC NULLS LAST,
                         importance DESC NULLS LAST, seq ASC NULLS LAST, createdAt ASC LIMIT ?
                """, arguments: [list, limit])
        }) ?? []
    }

    func doneItems(days: Int = 7, limit: Int = 30) -> [Item] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT * FROM item WHERE status = 'done' AND completedAt >= ?
                ORDER BY completedAt DESC LIMIT ?
                """, arguments: [since, limit])
        }) ?? []
    }

    func doneTodayCount() -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        return (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status = 'done' AND completedAt >= ?",
                             arguments: [start]) ?? 0
        }) ?? 0
    }

    func moveItem(_ id: Int64, toList list: String) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET gtdList = ?, status = 'clarified', updatedAt = ? WHERE id = ?",
                           arguments: [list, Date(), id])
        }
        Telemetry.record(event: "list_move", itemId: id, chosenPath: list)
    }

    /// item → 项目 id(顺序解锁用)
    func projectIds(forItems ids: [Int64]) -> [Int64: Int64] {
        guard !ids.isEmpty else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT itemId, projectId FROM itemProjectLink WHERE itemId IN (\(marks))",
                             arguments: StatementArguments(ids))
        }) ?? []
        var map: [Int64: Int64] = [:]
        for r in rows { map[r["itemId"]] = r["projectId"] }
        return map
    }

    /// 全局下一步行动:所有项目汇总一个列表;带 seq 的步骤每个项目只露出最靠前的一条,
    /// 完成前置才解锁后置(§需求)
    func globalNextActions(limit: Int = 30) -> [Item] {
        let all = actionableOpen(limit: 200)
        let pids = projectIds(forItems: all.compactMap(\.id))
        var loose: [Item] = []
        var frontOfChain: [Int64: Item] = [:]
        for it in all {
            if let id = it.id, let pid = pids[id], let s = it.seq {
                if let cur = frontOfChain[pid], (cur.seq ?? Int.max) <= s { continue }
                frontOfChain[pid] = it
            } else {
                loose.append(it)
            }
        }
        let merged = (loose + frontOfChain.values).sorted {
            let u0 = $0.urgency ?? 0, u1 = $1.urgency ?? 0
            if u0 != u1 { return u0 > u1 }
            let i0 = $0.importance ?? 0, i1 = $1.importance ?? 0
            if i0 != i1 { return i0 > i1 }
            return $0.createdAt < $1.createdAt
        }
        return Array(merged.prefix(limit))
    }

    /// 完成某步后,返回同项目链条上被解锁的下一步(用于「已解锁」toast)
    func unlockedStep(afterDone item: Item) -> Item? {
        guard let id = item.id, let seq = item.seq,
              let pid = projectIds(forItems: [id])[id] else { return nil }
        return try? dbQueue.read { db in
            try Item.fetchOne(db, sql: """
                SELECT item.* FROM item JOIN itemProjectLink l ON l.itemId = item.id
                WHERE l.projectId = ? AND item.status = 'clarified' AND item.seq > ?
                ORDER BY item.seq ASC LIMIT 1
                """, arguments: [pid, seq])
        } ?? nil
    }

    // MARK: - AI 拆解落库(自然计划法)

    func savePlan(projectId: Int64, purpose: String, outcome: String,
                  steps: [(action: String, remindAt: Date?)]) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET purpose = ?, outcome = ? WHERE id = ?",
                           arguments: [purpose, outcome, projectId])
            let maxSeq = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(item.seq), 0) FROM item
                JOIN itemProjectLink l ON l.itemId = item.id WHERE l.projectId = ?
                """, arguments: [projectId]) ?? 0
            for (i, step) in steps.enumerated() {
                var it = Item.newPlanStep(action: step.action, outcome: i == steps.count - 1 ? outcome : nil,
                                          seq: maxSeq + i + 1, remindAt: step.remindAt)
                try it.insert(db)
                if let iid = it.id {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO itemProjectLink (itemId, projectId, relation, createdAt)
                        VALUES (?, ?, 'primary', ?)
                        """, arguments: [iid, projectId, Date()])
                }
            }
        }
        Telemetry.record(event: "plan_saved", itemId: projectId,
                         suggestedPaths: steps.map(\.action), chosenRank: steps.count)
    }

    /// 项目截止日期(矩阵「紧急」的客观依据)
    func setProjectDue(_ id: Int64, date: Date?) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET dueDate = ? WHERE id = ?", arguments: [date, id])
        }
        Telemetry.record(event: "due_set", itemId: id, chosenPath: date.map { DateMention.format($0) })
    }

    /// 等待清单里搁太久的(催办候选):updatedAt 距今 ≥ days 天
    func staleWaiting(days: Int = 3) -> [Item] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT * FROM item WHERE status = 'clarified' AND gtdList = 'waiting'
                  AND updatedAt < ? ORDER BY updatedAt ASC LIMIT 5
                """, arguments: [cutoff])
        }) ?? []
    }

    /// 30 天没动过的活跃项目(复盘时提示完结/暂停)
    func staleProjects(days: Int = 30) -> [Project] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return (try? dbQueue.read { db in
            try Project.fetchAll(db, sql: """
                SELECT * FROM project WHERE status = 'active'
                  AND COALESCE(lastWorkedAt, createdAt) < ?
                ORDER BY COALESCE(lastWorkedAt, createdAt) ASC LIMIT 5
                """, arguments: [cutoff])
        }) ?? []
    }

    // MARK: - 提醒 / 复盘

    /// 到点且尚未弹过的提醒
    func dueReminders() -> [Item] {
        (try? dbQueue.read { db in
            try Item.fetchAll(db, sql: """
                SELECT * FROM item WHERE remindAt IS NOT NULL AND remindAt <= ?
                  AND remindedAt IS NULL
                  AND status IN ('inbox','clarified') ORDER BY remindAt ASC LIMIT 5
                """, arguments: [Date()])
        }) ?? []
    }

    /// 标记"已弹过":remindAt 保留,清单里继续显示红色逾期标,直到完成或改期
    func markReminded(_ id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET remindedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
    }

    func snoozeReminder(_ id: Int64, by seconds: TimeInterval) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET remindAt = ?, remindedAt = NULL, updatedAt = ? WHERE id = ?",
                           arguments: [Date().addingTimeInterval(seconds), Date(), id])
        }
        Telemetry.record(event: "remind_snooze", itemId: id)
    }

    struct WeekStats {
        var done = 0
        var captured = 0
        var archived = 0
        var inbox = 0
        var someday = 0
        var waiting = 0
        var overdue = 0
    }

    func weekStats() -> WeekStats {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        var s = WeekStats()
        try? dbQueue.read { db in
            s.done = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status='done' AND completedAt >= ?", arguments: [since]) ?? 0
            s.captured = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type IN ('idea','link') AND createdAt >= ?", arguments: [since]) ?? 0
            s.archived = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type='file' AND createdAt >= ?", arguments: [since]) ?? 0
            s.inbox = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type IN ('idea','link') AND status='inbox'") ?? 0
            s.someday = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status='clarified' AND gtdList='someday'") ?? 0
            s.waiting = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status='clarified' AND gtdList='waiting'") ?? 0
            s.overdue = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE remindAt < ? AND status IN ('inbox','clarified')", arguments: [Date()]) ?? 0
        }
        return s
    }

    /// item → 关联项目名(工作台矩阵/行动列表标注来源)
    func projectNames(forItems ids: [Int64]) -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.itemId AS itemId, p.name AS name FROM itemProjectLink l
                JOIN project p ON p.id = l.projectId WHERE l.itemId IN (\(marks))
                """, arguments: StatementArguments(ids))
        }) ?? []
        var map: [Int64: String] = [:]
        for r in rows { map[r["itemId"]] = r["name"] }
        return map
    }

    /// 理清结果落库:AI 出草稿,用户确认后调用
    func applyClarify(itemId: Int64, isActionable: Bool, nextAction: String?,
                      projectId: Int64?, importance: Int, urgency: Int,
                      list: String? = nil, expectedOutcome: String? = nil,
                      waitingFor: String? = nil, remindAt: Date? = nil) {
        // 不可执行的想法默认进搁置清单(将来也许);可执行默认进行动清单
        let resolvedList = list ?? (isActionable ? "action" : "someday")
        try? dbQueue.write { db in
            try db.execute(sql: """
                UPDATE item SET status = 'clarified', isActionable = ?, nextAction = ?,
                       importance = ?, urgency = ?, gtdList = ?, expectedOutcome = ?,
                       waitingFor = ?, remindAt = COALESCE(?, remindAt), remindedAt = NULL,
                       type = CASE WHEN ? AND type = 'idea' THEN 'task' ELSE type END,
                       updatedAt = ? WHERE id = ?
                """, arguments: [isActionable, nextAction, importance, urgency,
                                 resolvedList, expectedOutcome, waitingFor, remindAt,
                                 isActionable, Date(), itemId])
            if let pid = projectId {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO itemProjectLink (itemId, projectId, relation, createdAt)
                    VALUES (?, ?, 'primary', ?)
                    """, arguments: [itemId, pid, Date()])
            }
        }
    }

    func markItemDone(_ id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET status = 'done', completedAt = ?, updatedAt = ? WHERE id = ?",
                           arguments: [Date(), Date(), id])
        }
    }

    func dropItem(_ id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET status = 'dropped', updatedAt = ? WHERE id = ?",
                           arguments: [Date(), id])
        }
    }

    // MARK: - ActionLog / 撤销(§7)

    func logAction(_ action: String, itemId: Int64?, from: String, to: String) {
        try? dbQueue.write { db in
            var log = ActionLog(id: nil, action: action, itemId: itemId,
                                fromPath: from, toPath: to, timestamp: Date(), undone: false)
            try log.insert(db)
        }
    }

    func latestUndoableAction() -> ActionLog? {
        try? dbQueue.read { db in
            try ActionLog.fetchOne(db, sql: "SELECT * FROM actionLog WHERE undone = 0 AND action = 'archive' ORDER BY id DESC LIMIT 1")
        }
    }

    func markUndone(_ logId: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE actionLog SET undone = 1 WHERE id = ?", arguments: [logId])
        }
    }
}
