import AppKit
import Foundation

/// 聚焦模式(§4.3):时间盒计时 + 捕获默认关联 + 结束记一句进展。
/// 3 与 4 形成闭环:一次输入同时喂养智能关联与上下文恢复。
@MainActor
final class FocusManager {
    static let shared = FocusManager()

    struct Active {
        let projectId: Int64
        let projectName: String
        let projectPath: String
        let sessionId: Int64
        let startedAt: Date
        let boxMinutes: Int
    }

    private(set) var active: Active?
    private var timer: Timer?
    private var boxNotified = false

    /// 状态栏标题刷新回调(AppDelegate 注入)
    var onTick: ((String?) -> Void)?

    var isActive: Bool { active != nil }
    var activeProjectPath: String? { active?.projectPath }
    var activeProjectId: Int64? { active?.projectId }

    func start(project: Project, boxMinutes: Int = 25) {
        guard let pid = project.id else { return }
        end(note: nil)  // 收掉旧会话

        var session = FocusSession(id: nil, projectId: pid, startedAt: Date(), endedAt: nil, progressNote: nil)
        try? AppDatabase.shared.dbQueue.write { db in try session.insert(db) }
        guard let sid = session.id else { return }

        active = Active(projectId: pid, projectName: project.name, projectPath: project.path,
                        sessionId: sid, startedAt: Date(), boxMinutes: boxMinutes)
        boxNotified = false

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

    private func tick() {
        guard let a = active else { onTick?(nil); return }
        let elapsed = Int(Date().timeIntervalSince(a.startedAt))
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
        guard let a = active else { return }
        active = Active(projectId: a.projectId, projectName: a.projectName,
                        projectPath: a.projectPath, sessionId: a.sessionId,
                        startedAt: a.startedAt, boxMinutes: a.boxMinutes + minutes)
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
            contextChip: "已聚焦 \(Int(Date().timeIntervalSince(a.startedAt) / 60)) 分钟",
            icon: "flag.checkered",
            allowEmpty: true),
            onSubmit: { [weak self] note in
                self?.end(note: note.isEmpty ? nil : note)
            },
            onCancel: {
                // esc = 不结束:说清楚状态,避免"以为结束了其实还在计时"
                ToastManager.shared.show("仍在聚焦中(esc 取消了结束)。结束请再按一次或走菜单栏", duration: 3.5)
            })
    }

    func end(note: String?) {
        guard let a = active else { return }
        timer?.invalidate()
        timer = nil
        active = nil
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
}
