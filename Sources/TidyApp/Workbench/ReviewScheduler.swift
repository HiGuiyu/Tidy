import AppKit
import SwiftUI

/// 定期提醒与复盘调度(§需求):
/// - 单条 remindAt 到点 → 即时提醒(带解法:完成 / 推迟)
/// - 待办(行动清单):半天一次(09:30 / 14:30)
/// - 收件箱:每日一次(09:30,与待办合并成一条简报)
/// - 搁置清单:每周一 10:00
/// - 每周复盘:每周五 16:30 提示,可随时从菜单进入
/// 提醒永远带解法与入口按钮,不做"你有 N 项逾期"式的空提醒(原则 5)。
@MainActor
final class ReviewScheduler {
    static let shared = ReviewScheduler()

    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private var lastStretch = Date()

    var stretchOn: Bool {
        get { defaults.object(forKey: "stretchOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stretchOn") }
    }

    func start() {
        lastStretch = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in ReviewScheduler.shared.tick() }
        }
        // 启动 10 秒后先跑一轮(捕捉错过的提醒)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.tick() }
    }

    private func tick() {
        fireItemReminders()
        fireStretchReminder()
        fireHalfDayBrief()
        fireWaitingNudge()
        fireWeeklySomeday()
        fireWeeklyReviewPrompt()
    }

    // MARK: - 久坐提醒(每 50 分钟,照顾身体也是生产力)

    private func fireStretchReminder() {
        guard stretchOn, Date().timeIntervalSince(lastStretch) >= 50 * 60 else { return }
        lastStretch = Date()
        guard AttentionGovernor.shouldFire("stretch") else { return }
        Telemetry.record(event: "stretch_fired")
        if IslandController.shared.isVisible {
            IslandController.shared.present(event: IslandEvent(
                icon: "figure.walk", color: Theme.teal,
                title: "坐了 50 分钟了——站起来活动两分钟",
                subtitle: "倒杯水 · 看看远处 · 伸个懒腰",
                actions: [
                    IslandEvent.Action(label: "好的 ✓", prominent: true) {
                        Telemetry.record(event: "stretch_ok")
                    },
                    IslandEvent.Action(label: "再忙 10 分钟") { [weak self] in
                        self?.lastStretch = Date().addingTimeInterval(-40 * 60)
                    },
                ],
                duration: 20, kind: "stretch", silent: true))
        } else {
            ToastManager.shared.showLegacy("🧘 坐了 50 分钟了,站起来活动两分钟", duration: 10)
        }
    }

    // MARK: - 等待清单催办(搁 ≥3 天提示跟进,每日一次)

    private func fireWaitingNudge() {
        let now = Date()
        guard Calendar.current.component(.hour, from: now) >= 10 else { return }
        let key = "waitnudge-\(dayString(now))"
        guard !defaults.bool(forKey: key) else { return }
        let stale = AppDatabase.shared.staleWaiting(days: 3)
        defaults.set(true, forKey: key)
        guard let first = stale.first, AttentionGovernor.shouldFire("waiting") else { return }
        let days = Calendar.current.dateComponents([.day], from: first.updatedAt, to: now).day ?? 0
        let who = first.waitingFor.map { "(\($0))" } ?? ""
        Telemetry.record(event: "waiting_nudge", itemId: first.id)
        if IslandController.shared.isVisible {
            IslandController.shared.present(event: IslandEvent(
                icon: "hourglass", color: Theme.teal,
                title: "「\((first.nextAction ?? first.title).prefix(20))」\(who)已等 \(days) 天",
                subtitle: stale.count > 1 ? "另有 \(stale.count - 1) 条也在等——要跟进一下吗?" : "要跟进一下吗?",
                actions: [
                    IslandEvent.Action(label: "查看等待", prominent: true) {
                        WorkbenchController.shared.present(tab: .waiting)
                    },
                ],
                duration: 12, kind: "waiting", silent: true))
        } else {
            ToastManager.shared.showLegacy("⏳ 「\((first.nextAction ?? first.title).prefix(18))」已等 \(days) 天", duration: 10)
        }
    }

    // MARK: - 单条时间提醒

    private func fireItemReminders() {
        for item in AppDatabase.shared.dueReminders() {
            guard let id = item.id else { continue }
            AppDatabase.shared.markReminded(id)  // 只标记"弹过",逾期红标继续保留在清单里
            Telemetry.record(event: "remind_fired", itemId: id)
            let text = item.nextAction ?? item.title
            let names = AppDatabase.shared.projectNames(forItems: [id])
            // 岛事件卡:完成 / 推迟 1 小时 双按钮;岛隐藏时回退单按钮 toast
            if IslandController.shared.isVisible {
                // 项目在前,内容在后
                let title = names[id].map { "「\($0)」\(text.prefix(26))" } ?? String(text.prefix(34))
                IslandController.shared.present(event: IslandEvent(
                    icon: "bell.fill", color: Theme.warning,
                    title: title,
                    subtitle: "时间到了",
                    actions: [
                        IslandEvent.Action(label: "完成", prominent: true) {
                            AppDatabase.shared.markItemDone(id)
                            Telemetry.record(event: "done", itemId: id)
                            IslandController.shared.refresh()
                        },
                        IslandEvent.Action(label: "推迟 1h") {
                            AppDatabase.shared.snoozeReminder(id, by: 3600)
                            IslandController.shared.refresh()
                        },
                    ],
                    duration: 14, kind: "remind"))
            } else {
                ToastManager.shared.showLegacy("⏰ \(text.prefix(30))", actionTitle: "完成", duration: 12) {
                    AppDatabase.shared.markItemDone(id)
                    Telemetry.record(event: "done", itemId: id)
                }
            }
        }
    }

    // MARK: - 半天简报(待办 + 收件箱)

    private func fireHalfDayBrief() {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let slot: String
        if hour >= 9 && hour < 12 { slot = "am" }
        else if hour >= 14 && hour < 18 { slot = "pm" }
        else { return }
        let key = "brief-\(dayString(now))-\(slot)"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        let actions = AppDatabase.shared.globalNextActions(limit: 3)
        let inboxCount = AppDatabase.shared.inboxCaptures().count
        var parts: [String] = []
        if let top = actions.first {
            parts.append("最该做:「\((top.nextAction ?? top.title).prefix(20))」等 \(actions.count) 条行动")
        }
        if slot == "am", inboxCount > 0 {
            parts.append("收件箱 \(inboxCount) 条待理清")
        }
        guard !parts.isEmpty, AttentionGovernor.shouldFire("brief") else { return }
        Telemetry.record(event: "brief_shown", chosenPath: slot)
        let clarifyFirst = inboxCount > 0 && slot == "am"
        if IslandController.shared.isVisible {
            IslandController.shared.present(event: IslandEvent(
                icon: "sun.horizon.fill", color: Theme.accent,
                title: parts.joined(separator: " · "),
                subtitle: slot == "am" ? "上午简报" : "下午简报",
                actions: [
                    IslandEvent.Action(label: clarifyFirst ? "开始理清" : "打开工作台", prominent: true) {
                        if clarifyFirst { ClarifyController.shared.startQueue() }
                        else { WorkbenchController.shared.present() }
                    },
                ],
                duration: 12, kind: "brief", silent: true))
        } else {
            ToastManager.shared.showLegacy("📋 " + parts.joined(separator: " · "), duration: 10)
        }
    }

    // MARK: - 每周搁置清单扫描

    private func fireWeeklySomeday() {
        let now = Date()
        let cal = Calendar.current
        guard cal.component(.weekday, from: now) == 2,          // 周一
              cal.component(.hour, from: now) >= 10 else { return }
        let key = "someday-\(weekString(now))"
        guard !defaults.bool(forKey: key) else { return }
        let count = AppDatabase.shared.items(inList: "someday").count
        defaults.set(true, forKey: key)
        guard count > 0, AttentionGovernor.shouldFire("someday") else { return }
        Telemetry.record(event: "someday_review_prompt")
        if IslandController.shared.isVisible {
            IslandController.shared.present(event: IslandEvent(
                icon: "moon.zzz.fill", color: Theme.teal,
                title: "搁置清单有 \(count) 条",
                subtitle: "花 2 分钟扫一眼:该激活就激活,该放下就放下",
                actions: [
                    IslandEvent.Action(label: "查看", prominent: true) {
                        WorkbenchController.shared.present(tab: .someday)
                    },
                ],
                duration: 12, kind: "someday", silent: true))
        } else {
            ToastManager.shared.showLegacy("🌙 搁置清单有 \(count) 条,花 2 分钟扫一眼", duration: 12)
        }
    }

    // MARK: - 每周复盘提示

    private func fireWeeklyReviewPrompt() {
        let now = Date()
        let cal = Calendar.current
        guard cal.component(.weekday, from: now) == 6,          // 周五
              cal.component(.hour, from: now) >= 16 else { return }
        let key = "review-\(weekString(now))"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        Telemetry.record(event: "weekly_review_prompt")
        ToastManager.shared.show("🪞 周五了,花 5 分钟做每周复盘?", actionTitle: "开始复盘", duration: 15) {
            ReviewPanelController.shared.present()
        }
    }

    private func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    private func weekString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear ?? 0)-w\(c.weekOfYear ?? 0)"
    }
}

// MARK: - 每周复盘面板

@MainActor
final class ReviewPanelController {
    static let shared = ReviewPanelController()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?

    func present() {
        close()
        let stats = AppDatabase.shared.weekStats()
        let done = AppDatabase.shared.doneItems(days: 7, limit: 8)
        let stale = AppDatabase.shared.staleProjects(days: 30)
        Telemetry.record(event: "weekly_review_open")

        let view = ReviewView(stats: stats, done: done, staleProjects: stale,
                              onClarify: { [weak self] in self?.close(); ClarifyController.shared.startQueue() },
                              onOpenSomeday: { [weak self] in self?.close(); WorkbenchController.shared.present(tab: .someday) },
                              onClose: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting
        p.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - hosting.fittingSize.width / 2, y: f.minY + f.height * 0.82))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            if event.keyCode == 53 { self.close(); return nil }
            return event
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ReviewView: View {
    let stats: AppDatabase.WeekStats
    let done: [Item]
    let staleProjects: [Project]
    let onClarify: () -> Void
    let onOpenSomeday: () -> Void
    let onClose: () -> Void
    @State private var handledStale: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconBadge(systemName: "sparkle.magnifyingglass", color: Theme.accent)
                Text("每周复盘").font(Theme.fontTitle)
                Spacer()
                Text("esc 关闭").font(Theme.fontCaption).foregroundStyle(.tertiary)
            }
            // 本周成果(醒目位置:先看做完了什么)
            HStack(spacing: 10) {
                statBox("\(stats.done)", "已完成", Theme.success)
                statBox("\(stats.captured)", "新想法", Theme.accent)
                statBox("\(stats.archived)", "归档文件", Theme.violet)
                statBox("\(stats.overdue)", "已过提醒", stats.overdue > 0 ? Theme.danger : .secondary)
            }
            if stats.twoMin > 0 {
                Text("⚡ 其中 \(stats.twoMin) 件是「两分钟即办」——小事不过夜,没有进入任何清单")
                    .font(Theme.fontCaption).foregroundStyle(Theme.warning)
            }
            if !done.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本周完成的事").font(Theme.fontSub).foregroundStyle(Theme.success)
                    ForEach(done.prefix(6), id: \.id) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(Theme.success)
                            Text(item.nextAction ?? item.title).font(Theme.fontSub).lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.success.opacity(0.06)))
            }
            // 30 天没动的项目:提示完结或暂停(带解法,原则 5)
            if staleProjects.contains(where: { !handledStale.contains($0.id ?? -1) }) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("这些项目 30 天没动了", systemImage: "zzz")
                        .font(Theme.fontSub).foregroundStyle(Theme.warning)
                    ForEach(staleProjects, id: \.id) { p in
                        if let pid = p.id, !handledStale.contains(pid) {
                            HStack(spacing: 8) {
                                Text(p.name).font(Theme.fontSub).lineLimit(1)
                                if let t = p.lastWorkedAt {
                                    Text("上次 \(WorkbenchView.relative(t))")
                                        .font(Theme.fontMicro).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button("完结归档") {
                                    if ProjectLifecycle.archive(p) != nil {
                                        handledStale.insert(pid)
                                        ToastManager.shared.show("🎉 「\(p.name)」已完结归档", duration: 2.5)
                                    }
                                }
                                .controlSize(.mini).tint(Theme.success)
                                Button("暂停") {
                                    ProjectLifecycle.pause(p)
                                    handledStale.insert(pid)
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.06)))
            }
            // 建议(带解法,不带空任务)
            VStack(alignment: .leading, spacing: 6) {
                Text("建议").font(Theme.fontSub).foregroundStyle(.secondary)
                if stats.inbox > 0 {
                    suggestion("收件箱还有 \(stats.inbox) 条想法在等你 → 顺手理一理", "开始理清", onClarify)
                }
                if stats.someday > 0 {
                    suggestion("搁置清单 \(stats.someday) 条 → 扫一眼,激活或删除", "查看搁置", onOpenSomeday)
                }
                if stats.waiting > 0 {
                    Text("· 等待清单 \(stats.waiting) 条——有没有该催一催的?")
                        .font(Theme.fontSub).foregroundStyle(.secondary)
                }
                if stats.inbox == 0 && stats.someday == 0 && stats.waiting == 0 {
                    Text("· 系统很干净,保持 👍").font(Theme.fontSub).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("完成复盘", action: onClose).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(16)
        .panelChrome(width: 520)
    }

    private func statBox(_ num: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(num).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(Theme.fontMicro).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.07)))
    }

    private func suggestion(_ text: String, _ btn: String, _ action: @escaping () -> Void) -> some View {
        HStack {
            Text("· \(text)").font(Theme.fontSub).foregroundStyle(.secondary)
            Spacer()
            Button(btn, action: action).controlSize(.mini)
        }
    }
}
