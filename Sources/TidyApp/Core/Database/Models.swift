import Foundation
import GRDB

// MARK: - 数据模型(§6)

struct Item: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "item"
    var id: Int64?
    var type: String            // file | idea | link
    var title: String
    var content: String?
    var summary: String?
    var status: String          // inbox | clarified | archived | done | dropped
    var isActionable: Bool
    var nextAction: String?
    var importance: Int?
    var urgency: Int?
    var dueDate: Date?
    var filePath: String?
    var originalPath: String?
    var bookmarkData: Data?
    var source: String?
    var gtdList: String?        // action | waiting | someday(理清后路由到的清单)
    var expectedOutcome: String?// 任务 = 具体行动 + 期望结果
    var remindAt: Date?         // 文本里提到的时间 → 提醒标记
    var remindedAt: Date?       // 提醒已弹出的时间(避免重复弹;remindAt 保留以显示逾期)
    var seq: Int?               // 项目计划内的步骤序号(前置完成解锁后置)
    var waitingFor: String?     // 等待清单:等谁/等什么
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    static func newFile(title: String, filePath: String, originalPath: String, bookmark: Data?) -> Item {
        Item(id: nil, type: "file", title: title, content: nil, summary: nil,
             status: "archived", isActionable: false, nextAction: nil,
             importance: nil, urgency: nil, dueDate: nil,
             filePath: filePath, originalPath: originalPath, bookmarkData: bookmark,
             source: nil, gtdList: nil, expectedOutcome: nil, remindAt: nil, remindedAt: nil, seq: nil,
             waitingFor: nil, createdAt: Date(), updatedAt: Date(), completedAt: nil)
    }

    static func newCapture(text: String, source: String?, remindAt: Date? = nil) -> Item {
        let isLink = text.hasPrefix("http://") || text.hasPrefix("https://")
        let title = String(text.prefix(60))
        return Item(id: nil, type: isLink ? "link" : "idea", title: title,
                    content: text, summary: nil, status: "inbox", isActionable: false,
                    nextAction: nil, importance: nil, urgency: nil, dueDate: nil,
                    filePath: nil, originalPath: nil, bookmarkData: nil,
                    source: source, gtdList: nil, expectedOutcome: nil, remindAt: remindAt, remindedAt: nil,
                    seq: nil, waitingFor: nil, createdAt: Date(), updatedAt: Date(), completedAt: nil)
    }

    static func newPlanStep(action: String, outcome: String?, seq: Int, remindAt: Date?) -> Item {
        Item(id: nil, type: "task", title: String(action.prefix(60)), content: action, summary: nil,
             status: "clarified", isActionable: true, nextAction: action,
             importance: 1, urgency: 0, dueDate: nil,
             filePath: nil, originalPath: nil, bookmarkData: nil,
             source: "plan", gtdList: "action", expectedOutcome: outcome, remindAt: remindAt, remindedAt: nil,
             seq: seq, waitingFor: nil, createdAt: Date(), updatedAt: Date(), completedAt: nil)
    }
}

struct Project: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "project"
    var id: Int64?
    var name: String
    var path: String            // 相对 PARA 根的路径,如 "1-Projects/公司-客户A支付网关"
    var status: String          // active | paused | done
    var dueDate: Date?
    var lastWorkedAt: Date?
    var lastProgressNote: String?
    var purpose: String?        // AI 拆解:1 明确目的
    var outcome: String?        // AI 拆解:2 期望结果
    var createdAt: Date
    var completedAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct Area: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "area"
    var id: Int64?
    var name: String
    var path: String
    var reviewCadence: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ItemProjectLink: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemProjectLink"
    var itemId: Int64
    var projectId: Int64
    var relation: String        // primary | reference
    var createdAt: Date
}

struct Memory: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "memory"
    var id: Int64?
    var kind: String            // episodic | semantic | procedural | skill
    var content: String
    var tokens: String          // 预分词文本,供 FTS5 索引(CJK 二元切分)
    var scope: String           // global | project:<id> | area:<id> | profile:<company|personal>
    var confidence: Double
    var hitCount: Int
    var missCount: Int
    var lastUsedAt: Date?
    var supersedes: Int64?
    var condition: String?
    var sourceFile: String      // MEMORY.md | USER.md | db
    var createdAt: Date
    var decayedAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct Skill: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "skill"
    var id: Int64?
    var name: String
    var trigger: String
    var steps: String           // JSON
    var observedCount: Int
    var status: String          // suggested | active | disabled
    var lastRunAt: Date?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct MemoryDistillRun: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "memoryDistillRun"
    var id: Int64?
    var depth: Int
    var trigger: String         // cadence | weekly | focusEnd
    var inputEpisodicIds: String
    var producedIds: String
    var startedAt: Date
    var finishedAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ActionLog: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "actionLog"
    var id: Int64?
    var action: String          // archive | move | rename | delete
    var itemId: Int64?
    var fromPath: String
    var toPath: String
    var timestamp: Date
    var undone: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct FocusSession: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "focusSession"
    var id: Int64?
    var projectId: Int64
    var startedAt: Date
    var endedAt: Date?
    var progressNote: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct TelemetryRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "telemetry"
    var id: Int64?
    var event: String           // suggest | confirm | correct | fallbackSearch | undo
    var itemId: Int64?
    var suggestedPaths: String  // JSON [String]
    var suggestedScores: String // JSON [Double]
    var chosenPath: String?
    var chosenRank: Int?        // 1/2/3 = 命中第几位;nil = 走了模糊搜索
    var latencyMs: Int?
    var usedCloud: Bool
    var modelTier: String?      // light | heavy
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
