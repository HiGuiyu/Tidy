import Foundation
import SwiftUI

// MARK: - 草稿工具(与 Mac 端 summary JSON 同格式)

enum DraftBox {
    static func decode(_ item: Item) -> OpenAIClient.ClarifyDraft? {
        guard let s = item.summary, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OpenAIClient.ClarifyDraft.self, from: data)
    }

    /// 一句自然语言概括草稿(收件箱卡片用)
    static func summary(_ d: OpenAIClient.ClarifyDraft) -> String {
        if d.isLowConfidence, let q = d.question, !q.isEmpty { return "AI 想确认:\(q)" }
        if !d.isActionable { return "想法 → 搁置孵化" }
        var parts: [String] = []
        let listName = GTDList(rawValue: d.list)?.name ?? "行动"
        parts.append("\(listName):\(d.nextAction.prefix(24))")
        if !d.projectPath.isEmpty, let name = d.projectPath.components(separatedBy: "/").last {
            parts.append(name)
        }
        if d.important && d.urgent { parts.append("重要紧急") }
        else if d.important { parts.append("重要") }
        else if d.urgent { parts.append("紧急") }
        return parts.joined(separator: " · ")
    }

    /// 采纳草稿(与 Mac 端 ClarifyController.adopt 同逻辑)
    static func adopt(itemId: Int64, draft d: OpenAIClient.ClarifyDraft) {
        let projects = AppDatabase.shared.activeProjects()
        let pid = projects.first { $0.path == d.projectPath }?.id
        var remind: Date? = nil
        if !d.remindDate.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            remind = f.date(from: d.remindDate)
        }
        AppDatabase.shared.applyClarify(
            itemId: itemId, isActionable: d.isActionable,
            nextAction: d.isActionable && !d.nextAction.isEmpty ? d.nextAction : nil,
            projectId: pid,
            importance: d.important ? 1 : 0, urgency: d.urgent ? 1 : 0,
            list: d.isActionable ? d.list : "someday",
            expectedOutcome: d.expectedOutcome.isEmpty ? nil : d.expectedOutcome,
            waitingFor: d.list == "waiting" && !d.waitingFor.isEmpty ? d.waitingFor : nil,
            remindAt: remind)
        Telemetry.record(event: "clarify_adopt", itemId: itemId,
                         chosenPath: d.isActionable ? d.list : "someday", usedCloud: true)
    }

    /// 捕获后异步预理清(本地写入成功后才调用;失败只影响草稿)
    static func prewarm(itemId: Int64, text: String) {
        guard let client = OpenAIClient(config: EnvConfig.load()) else { return }
        Task {
            let projects = AppDatabase.shared.activeProjects()
            guard let draft = try? await client.clarify(
                text: text, projectPaths: projects.map(\.path),
                activeProjectPath: PhoneFocus.shared.activeProjectPath),
                  let json = try? JSONEncoder().encode(draft),
                  let str = String(data: json, encoding: .utf8) else { return }
            try? await AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE item SET summary = ? WHERE id = ? AND status = 'inbox'",
                               arguments: [str, itemId])
            }
        }
    }
}

// MARK: - 移动端专注引擎
// 计时以持久化的 startedAt / pausedAccum 为真相,进程内不依赖 tick;
// App 被杀或重启后按持久化状态恢复询问,不静默丢失。

@MainActor
final class PhoneFocus: ObservableObject {
    static let shared = PhoneFocus()

    @Published private(set) var projectId: Int64?
    @Published private(set) var projectName: String?
    @Published private(set) var actionTitle: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var boxMinutes = 25
    @Published private(set) var pausedAt: Date?
    @Published private(set) var pausedAccum: TimeInterval = 0
    private var sessionId: Int64?

    var isActive: Bool { startedAt != nil }
    var isPaused: Bool { pausedAt != nil }
    var activeProjectPath: String? {
        guard let pid = projectId else { return nil }
        return AppDatabase.shared.project(byId: pid)?.path
    }

    private init() { restore() }

    var elapsed: Int {
        guard let s = startedAt else { return 0 }
        let pausing = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, Int(Date().timeIntervalSince(s) - pausedAccum - pausing))
    }

    var remaining: Int { boxMinutes * 60 - elapsed }

    func start(actionTitle: String?, projectId pid: Int64?, minutes: Int) {
        end(note: nil, silent: true)
        self.actionTitle = actionTitle
        projectId = pid
        projectName = pid.flatMap { AppDatabase.shared.project(byId: $0)?.name }
        boxMinutes = minutes
        startedAt = Date()
        pausedAt = nil
        pausedAccum = 0
        if let pid {
            var session = FocusSession(id: nil, projectId: pid, startedAt: Date(), endedAt: nil, progressNote: nil)
            try? AppDatabase.shared.dbQueue.write { db in try session.insert(db) }
            sessionId = session.id
        }
        Telemetry.record(event: "focus_start_phone", itemId: pid)
        persist()
    }

    func pause() {
        guard isActive, pausedAt == nil else { return }
        pausedAt = Date()
        persist()
    }

    func resume() {
        guard let p = pausedAt else { return }
        pausedAccum += Date().timeIntervalSince(p)
        pausedAt = nil
        persist()
    }

    func extend(minutes: Int) {
        boxMinutes += minutes
        persist()
    }

    func end(note: String?, silent: Bool = false) {
        guard isActive else { return }
        if let sid = sessionId {
            try? AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE focusSession SET endedAt = ?, progressNote = ? WHERE id = ?",
                               arguments: [Date(), note, sid])
            }
        }
        if let pid = projectId {
            try? AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE project SET lastWorkedAt = ?, lastProgressNote = COALESCE(?, lastProgressNote) WHERE id = ?",
                               arguments: [Date(), note, pid])
            }
            if let note, !note.isEmpty {
                MemoryStore.shared.recordEpisodic("\(dateStr()) 聚焦「\(projectName ?? "")」进展:\(note)",
                                                  scope: "project:\(pid)")
            }
        }
        projectId = nil
        projectName = nil
        actionTitle = nil
        startedAt = nil
        pausedAt = nil
        pausedAccum = 0
        sessionId = nil
        persist()
        if !silent { PhoneToast.shared.show(note?.isEmpty == false ? "已记录进展 ✓" : "专注已结束") }
    }

    // MARK: 持久化(崩溃/重启恢复)

    private func persist() {
        let d = UserDefaults.standard
        guard let s = startedAt else {
            d.removeObject(forKey: "pf.state")
            return
        }
        d.set([
            "started": s.timeIntervalSince1970,
            "box": boxMinutes,
            "accum": pausedAccum + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0),
            "pid": projectId ?? -1,
            "sid": sessionId ?? -1,
            "action": actionTitle ?? "",
            "pname": projectName ?? "",
        ] as [String: Any], forKey: "pf.state")
    }

    private func restore() {
        guard let d = UserDefaults.standard.dictionary(forKey: "pf.state"),
              let ts = d["started"] as? TimeInterval else { return }
        startedAt = Date(timeIntervalSince1970: ts)
        boxMinutes = d["box"] as? Int ?? 25
        pausedAccum = d["accum"] as? TimeInterval ?? 0
        pausedAt = Date()   // 恢复时先置暂停:进程死亡期间不计入专注,由用户决定继续或结束
        let pid = d["pid"] as? Int ?? -1
        projectId = pid >= 0 ? Int64(pid) : nil
        let sid = d["sid"] as? Int ?? -1
        sessionId = sid >= 0 ? Int64(sid) : nil
        actionTitle = (d["action"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        projectName = (d["pname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - 两分钟即办(倒计时以 deadline 为真相)

@MainActor
final class PhoneTwoMin: ObservableObject {
    static let shared = PhoneTwoMin()

    @Published private(set) var itemId: Int64?
    @Published private(set) var title = ""
    @Published private(set) var deadline: Date?

    var isActive: Bool { deadline != nil }
    var remaining: Int { deadline.map { max(0, Int($0.timeIntervalSinceNow)) } ?? 0 }
    var isTimeUp: Bool { isActive && remaining == 0 }

    private init() { restore() }

    func start(itemId id: Int64, title t: String) {
        itemId = id
        title = t
        deadline = Date().addingTimeInterval(120)
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET status = 'clarified', gtdList = 'doing', updatedAt = ? WHERE id = ?",
                           arguments: [Date(), id])
        }
        Telemetry.record(event: "two_min_start", itemId: id)
        persist()
    }

    func finish(done: Bool) {
        guard let id = itemId else { return }
        if done {
            AppDatabase.shared.markItemDone(id)
            Telemetry.record(event: "two_min_done", itemId: id)
            MemoryStore.shared.recordEpisodic("\(dateStr()) ⚡ 两分钟即办:\(title.prefix(40))")
            PhoneToast.shared.show("⚡ 两分钟即办 +1")
        } else {
            try? AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE item SET status = 'inbox', gtdList = NULL, updatedAt = ? WHERE id = ?",
                               arguments: [Date(), id])
            }
            Telemetry.record(event: "two_min_giveup", itemId: id)
        }
        itemId = nil
        title = ""
        deadline = nil
        persist()
    }

    private func persist() {
        let d = UserDefaults.standard
        guard let dl = deadline, let id = itemId else {
            d.removeObject(forKey: "p2m.state")
            return
        }
        d.set(["deadline": dl.timeIntervalSince1970, "id": id, "title": title] as [String: Any],
              forKey: "p2m.state")
    }

    private func restore() {
        guard let d = UserDefaults.standard.dictionary(forKey: "p2m.state"),
              let ts = d["deadline"] as? TimeInterval,
              let id = (d["id"] as? Int).map(Int64.init) ?? (d["id"] as? Int64) else { return }
        itemId = id
        title = d["title"] as? String ?? ""
        deadline = Date(timeIntervalSince1970: ts)
        // 到时后的实际结果由 Today 卡询问,不静默判定
    }
}

// MARK: - Today 系统提示(一次只展示优先级最高的一项)

struct SystemHint: Identifiable {
    let id = UUID()
    var icon: String
    var color: Color
    var text: String
    var actionTitle: String
    var kind: Kind

    enum Kind { case overdue, inbox, waiting }

    @MainActor
    static func top() -> SystemHint? {
        let db = AppDatabase.shared
        let overdue = (try? db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM item WHERE remindAt < ? AND status IN ('inbox','clarified')",
                             arguments: [Date()]) ?? 0
        }) ?? 0
        if overdue > 0 {
            return SystemHint(icon: "bell.badge.fill", color: PT.danger,
                              text: "\(overdue) 条提醒已到点", actionTitle: "去处理", kind: .overdue)
        }
        let inbox = db.inboxCaptures(limit: 50).count
        if inbox > 0 {
            return SystemHint(icon: "tray.full.fill", color: PT.warning,
                              text: "收件箱有 \(inbox) 条待理清", actionTitle: "开始理清", kind: .inbox)
        }
        if let stale = db.staleWaiting(days: 3).first {
            let days = Calendar.current.dateComponents([.day], from: stale.updatedAt, to: Date()).day ?? 0
            return SystemHint(icon: "hourglass", color: PT.teal,
                              text: "「\((stale.nextAction ?? stale.title).prefix(16))」已等 \(days) 天",
                              actionTitle: "看等待", kind: .waiting)
        }
        return nil
    }
}

func dateStr() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}
