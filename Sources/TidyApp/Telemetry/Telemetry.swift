import Foundation
import GRDB

/// 埋点(§10.4):全部写本地 GRDB,不出网。一条 SQL 可算出全部 P0 验收指标。
enum Telemetry {
    static func record(event: String,
                       itemId: Int64? = nil,
                       suggestedPaths: [String] = [],
                       suggestedScores: [Double] = [],
                       chosenPath: String? = nil,
                       chosenRank: Int? = nil,
                       latencyMs: Int? = nil,
                       usedCloud: Bool = false,
                       modelTier: String? = nil) {
        let paths = String(data: (try? JSONEncoder().encode(suggestedPaths)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let scores = String(data: (try? JSONEncoder().encode(suggestedScores)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        try? AppDatabase.shared.dbQueue.write { db in
            var row = TelemetryRow(id: nil, event: event, itemId: itemId,
                                   suggestedPaths: paths, suggestedScores: scores,
                                   chosenPath: chosenPath, chosenRank: chosenRank,
                                   latencyMs: latencyMs, usedCloud: usedCloud,
                                   modelTier: modelTier, createdAt: Date())
            try row.insert(db)
        }
    }

    /// 数据分析(工作台「统计」页):理清率、两分钟命中率、GTD 漏斗、归档指标
    struct Analytics {
        // GTD 漏斗(基于 item 表,全量)
        var captured = 0        // 捕获的想法/链接/任务
        var clarified = 0       // 已理清(含后续完成/丢弃)
        var doneTotal = 0       // 已完成
        var dropped = 0
        // 行为率(基于埋点)
        var twoMin = 0          // 两分钟规则立即完成
        var listMoves = 0
        var planSaved = 0
        var remindFired = 0
        var done7 = 0           // 近 7 天完成
        // 清单存量
        var inboxNow = 0, actionNow = 0, waitingNow = 0, somedayNow = 0
        var oldestInboxDays: Int? = nil   // 收件箱最老条目年龄——比 Inbox Zero 更诚实的健康指标
        // 归档
        var archiveTotal = 0, rank1 = 0, ranked = 0, fallbackCount = 0
        var avgLatency = 0, cloudPct = 0
        var memoryCount = 0

        var clarifyRate: Int { captured > 0 ? Int(Double(clarified) * 100 / Double(captured)) : 0 }
        var doneRate: Int { clarified > 0 ? Int(Double(doneTotal) * 100 / Double(clarified)) : 0 }
        var hitRate: Int { archiveTotal > 0 ? Int(Double(rank1) * 100 / Double(archiveTotal)) : 0 }
        var twoMinRate: Int { captured > 0 ? Int(Double(twoMin) * 100 / Double(captured)) : 0 }
    }

    static func analytics() -> Analytics {
        var a = Analytics()
        try? AppDatabase.shared.dbQueue.read { db in
            // 漏斗(item 表为真相源)
            a.captured = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type IN ('idea','link','task') AND (source IS NULL OR source != 'plan')") ?? 0
            a.clarified = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type IN ('idea','link','task') AND (source IS NULL OR source != 'plan') AND status != 'inbox'") ?? 0
            a.doneTotal = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type IN ('idea','link','task') AND status = 'done'") ?? 0
            a.dropped = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type IN ('idea','link','task') AND status = 'dropped'") ?? 0
            // 行为
            a.twoMin = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event = 'two_min_done'") ?? 0
            a.listMoves = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event = 'list_move'") ?? 0
            a.planSaved = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event = 'plan_saved'") ?? 0
            a.remindFired = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event = 'remind_fired'") ?? 0
            let week = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            a.done7 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status = 'done' AND completedAt >= ?", arguments: [week]) ?? 0
            // 存量
            a.inboxNow = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE type IN ('idea','link') AND status = 'inbox'") ?? 0
            a.actionNow = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status = 'clarified' AND gtdList = 'action'") ?? 0
            a.waitingNow = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status = 'clarified' AND gtdList = 'waiting'") ?? 0
            a.somedayNow = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE status = 'clarified' AND gtdList = 'someday'") ?? 0
            if let oldest = try Date.fetchOne(db, sql: "SELECT MIN(createdAt) FROM item WHERE type IN ('idea','link') AND status = 'inbox'") {
                a.oldestInboxDays = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day
            }
            // 归档
            a.archiveTotal = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct')") ?? 0
            a.rank1 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND chosenRank = 1") ?? 0
            a.ranked = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND chosenRank IS NOT NULL") ?? 0
            a.fallbackCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND chosenRank IS NULL") ?? 0
            a.avgLatency = try Int.fetchOne(db, sql: "SELECT CAST(AVG(latencyMs) AS INTEGER) FROM telemetry WHERE event IN ('confirm','correct') AND latencyMs IS NOT NULL") ?? 0
            let cloud = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND usedCloud = 1") ?? 0
            a.cloudPct = a.archiveTotal > 0 ? Int(Double(cloud) * 100 / Double(a.archiveTotal)) : 0
            a.memoryCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE decayedAt IS NULL") ?? 0
        }
        return a
    }

    /// 统计摘要(状态栏菜单「统计」)
    static func summary() -> String {
        let db = AppDatabase.shared.dbQueue
        struct Stats { var total = 0; var rank1 = 0; var ranked = 0; var fallback = 0; var avgLatency = 0; var cloud = 0; var undo = 0 }
        var s = Stats()
        try? db.read { dbx in
            s.total = try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct')") ?? 0
            s.rank1 = try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND chosenRank = 1") ?? 0
            s.ranked = try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND chosenRank IS NOT NULL") ?? 0
            s.fallback = try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND chosenRank IS NULL") ?? 0
            s.avgLatency = try Int.fetchOne(dbx, sql: "SELECT CAST(AVG(latencyMs) AS INTEGER) FROM telemetry WHERE event IN ('confirm','correct') AND latencyMs IS NOT NULL") ?? 0
            s.cloud = try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM telemetry WHERE event IN ('confirm','correct') AND usedCloud = 1") ?? 0
            s.undo = try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM telemetry WHERE event = 'undo'") ?? 0
        }
        guard s.total > 0 else { return "还没有归档记录。拖一个文件到悬浮窗试试!" }
        let hitRate = s.total > 0 ? Int(Double(s.rank1) / Double(s.total) * 100) : 0
        let memCount = (try? AppDatabase.shared.dbQueue.read { dbx in
            try Int.fetchOne(dbx, sql: "SELECT COUNT(*) FROM memory WHERE decayedAt IS NULL") ?? 0
        }) ?? 0
        return """
        归档总数:\(s.total)
        首选命中率:\(hitRate)%(P0 验收 > 70%,第 2 周起统计)
        命中 top-3:\(s.ranked) 次 · 走模糊搜索:\(s.fallback) 次
        平均耗时:\(s.avgLatency) ms
        云端调用占比:\(s.total > 0 ? Int(Double(s.cloud) / Double(s.total) * 100) : 0)%
        撤销次数:\(s.undo)
        记忆条数:\(memCount)(随使用增长)
        """
    }
}
