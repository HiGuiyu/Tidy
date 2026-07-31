import AppKit
import Foundation

/// 聚焦模式(§4.3):时间盒计时 + 捕获默认关联 + 结束记一句进展。
/// Beat 状态机补全:支持暂停/继续、中断记录("回来后从哪里继续")、
/// 设备睡眠自动暂停并在唤醒时校准、崩溃后恢复询问——绝不静默丢失或虚增专注时长。
@MainActor
final class FocusManager {
    static let shared = FocusManager()

    struct Active {
        let projectId: Int64
        let projectName: String
        let projectPath: String
        let sessionId: Int64
        let startedAt: Date
        var boxMinutes: Int
    }

    private(set) var active: Active?
    private var timer: Timer?
    private var boxNotified = false

    // 暂停状态
    private var pausedAt: Date?
    private var pausedAccum: TimeInterval = 0
    private var resumeNote: String?
    private var sleepAutoPaused = false

    /// 状态栏标题刷新回调(AppDelegate 注入)
    var onTick: ((String?) -> Void)?

    var isActive: Bool { active != nil }
    var isPaused: Bool { pausedAt != nil }
    var activeProjectPath: String? { active?.projectPath }
    var activeProjectId: Int64? { active?.projectId }

    private init() {
        // 设备睡眠 = 自动暂停;唤醒 = 询问,不推断"仍在进行"
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in FocusManager.shared.systemWillSleep() }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in FocusManager.shared.systemDidWake() }
        }
    }

    /// 净专注时长(秒):扣除全部暂停时间
    private var elapsedSeconds: Int {
        guard let a = active else { return 0 }
        let pausing = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, Int(Date().timeIntervalSince(a.startedAt) - pausedAccum - pausing))
    }

    func start(project: Project, boxMinutes: Int = 25) {
        guard let pid = project.id else { return }
        end(note: nil)  // 收掉旧会话

        var session = FocusSession(id: nil, projectId: pid, startedAt: Date(), endedAt: nil, progressNote: nil)
        try? AppDatabase.shared.dbQueue.write { db in try session.insert(db) }
        guard let sid = session.id else { return }

        active = Active(projectId: pid, projectName: project.name, projectPath: project.path,
                        sessionId: sid, startedAt: Date(), boxMinutes: boxMinutes)
        boxNotified = false
        pausedAt = nil
        pausedAccum = 0
        resumeNote = nil
        saveRecovery()

        // 自动打开项目目录 / 上次编辑的文件
        let dir = ParaTree.root.appendingPathComponent(project.path)
        if let recent = ParaTree.recentFiles(in: dir, limit: 1).first {
            NSWorkspace.shared.activateFileViewerSelecting([recent.url])
        } else {
            NSWorkspace.shared.open(dir)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        ToastManager.shared.show("已进入聚焦:\(project.name)(\(boxMinutes) 分钟时间盒,期间捕获自动关联)")
    }

    // MARK: - 暂停 / 中断 / 继续

    /// 暂停并记录中断("回来后从哪里继续")
    func requestPause() {
        guard isActive, !isPaused else { return }
        InputPanelController.shared.present(.init(
            title: "暂停聚焦",
            placeholder: "一句话:回来后从哪里继续?(直接 ↵ 可跳过)",
            icon: "pause.circle",
            allowEmpty: true)) { [weak self] note in
            self?.pause(note: note.isEmpty ? nil : note)
        }
    }

    func pause(note: String?) {
        guard isActive, pausedAt == nil else { return }
        pausedAt = Date()
        if let note { resumeNote = note }
        Telemetry.record(event: "focus_pause", itemId: active?.projectId)
        saveRecovery()
        tick()
    }

    func resume() {
        guard let p = pausedAt else { return }
        pausedAccum += Date().timeIntervalSince(p)
        pausedAt = nil
        sleepAutoPaused = false
        Telemetry.record(event: "focus_resume", itemId: active?.projectId)
        if let n = resumeNote {
            ToastManager.shared.show("回来继续:\(n)", duration: 5)
        }
        resumeNote = nil
        saveRecovery()
        tick()
    }

    // MARK: - 睡眠校准

    private func systemWillSleep() {
        guard isActive, !isPaused else { return }
        sleepAutoPaused = true
        pause(note: nil)
    }

    private func systemDidWake() {
        guard isActive, sleepAutoPaused else { return }
        let a = active!
        let mins = elapsedSeconds / 60
        IslandController.shared.present(event: IslandEvent(
            icon: "moon.fill", color: Theme.teal,
            title: "睡眠期间「\(a.projectName)」已自动暂停",
            subtitle: "已专注 \(mins) 分钟",
            actions: [
                IslandEvent.Action(label: "继续", prominent: true) { [weak self] in
                    self?.resume()
                },
                IslandEvent.Action(label: "结束并记录") { [weak self] in
                    self?.requestEnd()
                },
            ],
            duration: 30, kind: "focus_wake"))
    }

    // MARK: - 计时

    private func tick() {
        guard let a = active else { onTick?(nil); return }
        let elapsed = elapsedSeconds
        if elapsed % 60 == 0 { saveRecovery() }   // 崩溃恢复:每分钟落一次盘
        if isPaused {
            onTick?("⏸ \(formatMMSS(elapsed)) \(a.projectName.prefix(6))")
            return
        }
        let remain = a.boxMinutes * 60 - elapsed
        if remain <= 0 {
            if !boxNotified {
                boxNotified = true
                // 岛事件卡:时间盒结束,双按钮(结束并记录 / 再来 25 分钟)
                if IslandController.shared.isVisible {
                    IslandController.shared.present(event: IslandEvent(
                        icon: "timer", color: Theme.success,
                        title: "「\(a.projectName)」时间盒到了",
                        subtitle: "已专注 \(a.boxMinutes) 分钟",
                        actions: [
                            IslandEvent.Action(label: "结束并记录", prominent: true) { [weak self] in
                                self?.requestEnd()
                            },
                            IslandEvent.Action(label: "再来 25 分钟") { [weak self] in
                                self?.extend(minutes: 25)
                            },
                        ],
                        duration: 15, kind: "timebox"))
                } else {
                    ToastManager.shared.showLegacy("⏰ \(a.projectName) 的时间盒到了", actionTitle: "结束聚焦") { [weak self] in
                        self?.requestEnd()
                    }
                }
            }
            onTick?("⏱ +\(formatMMSS(-remain)) \(a.projectName.prefix(6))")
        } else {
            onTick?("⏱ \(formatMMSS(remain)) \(a.projectName.prefix(6))")
        }
    }

    private func formatMMSS(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 时间盒续期(岛卡片「再来 25 分钟」)
    func extend(minutes: Int) {
        guard var a = active else { return }
        a.boxMinutes += minutes
        active = a
        boxNotified = false
        Telemetry.record(event: "focus_extend", itemId: a.projectId)
        tick()
    }

    /// 弹进展输入框再结束(提取记忆的最佳时机,§4.5.11)
    func requestEnd() {
        guard let a = active else { return }
        InputPanelController.shared.present(.init(
            title: "结束聚焦:\(a.projectName)",
            placeholder: "一句话:这次做到哪了?(直接 ↵ 可跳过记录)",
            contextChip: "已专注 \(elapsedSeconds / 60) 分钟",
            icon: "flag.checkered",
            allowEmpty: true),
            onSubmit: { [weak self] note in
                self?.end(note: note.isEmpty ? nil : note)
            },
            onCancel: {
                // esc = 不结束:说清楚状态,避免"以为结束了其实还在计时"
                ToastManager.shared.show("仍在聚焦中(esc 取消了结束)。结束请再按一次或走岛菜单", duration: 3.5)
            })
    }

    func end(note: String?) {
        guard let a = active else { return }
        timer?.invalidate()
        timer = nil
        active = nil
        pausedAt = nil
        pausedAccum = 0
        resumeNote = nil
        sleepAutoPaused = false
        clearRecovery()
        onTick?(nil)

        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE focusSession SET endedAt = ?, progressNote = ? WHERE id = ?",
                           arguments: [Date(), note, a.sessionId])
            try db.execute(sql: "UPDATE project SET lastWorkedAt = ?, lastProgressNote = COALESCE(?, lastProgressNote) WHERE id = ?",
                           arguments: [Date(), note, a.projectId])
        }
        if let note, !note.isEmpty {
            MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 聚焦「\(a.projectName)」进展:\(note)",
                                              scope: "project:\(a.projectId)")
            ToastManager.shared.show("已记录进展,下次打开工作台可直接接上")
        } else {
            ToastManager.shared.show("聚焦已结束", duration: 2)
        }
    }

    // MARK: - 崩溃恢复(重启时不推断"仍在进行",而是询问)

    private func saveRecovery() {
        guard let a = active else { clearRecovery(); return }
        UserDefaults.standard.set([
            "name": a.projectName,
            "sid": a.sessionId,
            "pid": a.projectId,
            "elapsed": elapsedSeconds,
            "note": resumeNote ?? "",
        ] as [String: Any], forKey: "focusRecovery")
    }

    private func clearRecovery() {
        UserDefaults.standard.removeObject(forKey: "focusRecovery")
    }

    /// App 启动时调用:上次聚焦未正常结束 → 询问,不自动完成也不静默丢弃
    func checkRecovery() {
        guard active == nil,
              let d = UserDefaults.standard.dictionary(forKey: "focusRecovery"),
              let name = d["name"] as? String,
              let sid = d["sid"] as? Int64 ?? (d["sid"] as? Int).map(Int64.init),
              let pid = d["pid"] as? Int64 ?? (d["pid"] as? Int).map(Int64.init) else { return }
        let elapsed = (d["elapsed"] as? Int) ?? 0
        clearRecovery()
        guard elapsed >= 60 else {
            // 不足一分钟的残留会话直接安静收尾
            try? AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM focusSession WHERE id = ? AND endedAt IS NULL", arguments: [sid])
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            IslandController.shared.present(event: IslandEvent(
                icon: "arrow.counterclockwise", color: Theme.teal,
                title: "上次聚焦「\(name)」未正常结束",
                subtitle: "已专注约 \(elapsed / 60) 分钟",
                actions: [
                    IslandEvent.Action(label: "记录时长 ✓", prominent: true) {
                        try? AppDatabase.shared.dbQueue.write { db in
                            try db.execute(sql: """
                                UPDATE focusSession SET endedAt = ?, progressNote = COALESCE(progressNote, '(异常恢复)')
                                WHERE id = ? AND endedAt IS NULL
                                """, arguments: [Date(), sid])
                            try db.execute(sql: "UPDATE project SET lastWorkedAt = ? WHERE id = ?",
                                           arguments: [Date(), pid])
                        }
                        Telemetry.record(event: "focus_recovered", itemId: pid)
                    },
                    IslandEvent.Action(label: "丢弃") {
                        try? AppDatabase.shared.dbQueue.write { db in
                            try db.execute(sql: "DELETE FROM focusSession WHERE id = ? AND endedAt IS NULL", arguments: [sid])
                        }
                    },
                ],
                duration: 30, kind: "focus_recover"))
        }
    }
}
