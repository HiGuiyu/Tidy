import AppKit
import SwiftUI

/// 项目工作台(⌥⌘P):飞书式标签页。
/// 总览 = GTD 仪表盘;收件箱/行动/等待/搁置/已完成 = 五个清单页,每页带适用说明。
/// 所有项目的下一步行动汇总在「行动」一个列表里,完成前置步骤自动解锁后置。
@MainActor
final class WorkbenchController {
    static let shared = WorkbenchController()

    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var model: WorkbenchModel?

    enum Tab: String, CaseIterable {
        case overview, inbox, action, waiting, someday, done, stats

        var name: String {
            switch self {
            case .overview: return "总览"
            case .inbox: return "收件箱"
            case .action: return "行动"
            case .waiting: return "等待"
            case .someday: return "搁置"
            case .done: return "已完成"
            case .stats: return "统计"
            }
        }

        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2.fill"
            case .inbox: return "tray.fill"
            case .action: return "bolt.fill"
            case .waiting: return "hourglass"
            case .someday: return "moon.zzz.fill"
            case .done: return "checkmark.circle.fill"
            case .stats: return "chart.bar.fill"
            }
        }

        var color: Color {
            switch self {
            case .overview: return Theme.accent
            case .inbox: return Theme.warning
            case .action: return Theme.accent
            case .waiting: return Theme.teal
            case .someday: return .gray
            case .done: return Theme.success
            case .stats: return Theme.violet
            }
        }
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { present() }
    }

    func present(tab: Tab = .overview) {
        close()
        _ = ParaTree.shared.freshDestinations()
        let m = WorkbenchModel()
        m.tab = tab
        m.reload()
        model = m
        Telemetry.record(event: "workbench_open", chosenPath: tab.rawValue)

        let view = WorkbenchView(model: m,
                                 onClose: { [weak self] in self?.close() },
                                 onStartFocus: { [weak self] project in
                                     self?.close()
                                     FocusManager.shared.start(project: project)
                                 })
        let hosting = NSHostingView(rootView: view)
        let width: CGFloat = 840
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 620),
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
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - width / 2, y: f.minY + f.height * 0.87))
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow, let m = self.model else { return event }
            let cmd = event.modifierFlags.contains(.command)
            // ⌘1-7 切标签页
            if cmd, let ch = event.charactersIgnoringModifiers, let n = Int(ch),
               (1...Tab.allCases.count).contains(n) {
                m.tab = Tab.allCases[n - 1]
                return nil
            }
            // ⌘N 新建项目(应用内直接建,不用去 Finder)
            if cmd, event.keyCode == 45 {
                NewProjectController.shared.present { [weak m] _ in m?.reload() }
                return nil
            }
            switch event.keyCode {
            case 53:
                // esc 逐级返回:详情 → 列表;有搜索词 → 清空;否则关闭(与归档面板一致)
                if m.detail != nil { m.detail = nil }
                else if !m.query.isEmpty { m.query = "" }
                else { self.close() }
                return nil
            case 36, 76:
                guard m.detail == nil else { return event }
                if m.tab == .overview || !m.query.isEmpty {
                    if m.results.indices.contains(m.selectedIndex) {
                        m.open(project: m.results[m.selectedIndex])
                    }
                } else {
                    m.primaryAction()  // 清单页:↵ = 完成 / 理清选中行
                }
                return nil
            case 126, 125:
                guard m.detail == nil else { return event }
                let delta = event.keyCode == 126 ? -1 : 1
                if m.tab == .overview || !m.query.isEmpty {
                    m.selectedIndex = min(max(0, m.selectedIndex + delta), max(0, m.results.count - 1))
                } else {
                    m.listSelection = min(max(0, m.listSelection + delta), max(0, m.listRowCount - 1))
                }
                return nil
            default:
                return event
            }
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}

// MARK: - 数据模型(全部自动聚合,零手工维护)

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var tab: WorkbenchController.Tab = .overview { didSet { listSelection = 0 } }
    @Published var listSelection = 0        // 清单页里键盘选中的行
    @Published var query = "" { didSet { filter() } }
    @Published var results: [Project] = []
    @Published var selectedIndex = 0
    @Published var detail: ProjectDetail? = nil
    @Published var inbox: [Item] = []
    @Published var inboxEntries: [InboxEntry] = []   // 收件箱条目 + 预理清草稿

    struct InboxEntry: Identifiable {
        let item: Item
        let draft: OpenAIClient.ClarifyDraft?
        var id: Int64 { item.id ?? 0 }

        /// 草稿一行摘要:「行动:催张三 · 客户A支付网关 · 重要」
        var draftSummary: String? {
            guard let d = draft else { return nil }
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
            if d.twoMinutes { parts.append("⚡2分钟") }
            return parts.joined(separator: " · ")
        }
    }
    @Published var nextActions: [ActionRow] = []       // 全局行动(顺序解锁后)
    @Published var waiting: [ActionRow] = []
    @Published var someday: [ActionRow] = []
    @Published var doneRecent: [ActionRow] = []
    @Published var doneToday = 0
    @Published var quadrants: [[ActionRow]] = [[], [], [], []]

    private var all: [Project] = []
    private var keys: [Int64: SearchKey] = [:]

    struct ActionRow: Identifiable {
        let item: Item
        let projectName: String?
        var id: Int64 { item.id ?? 0 }
        var text: String { item.nextAction ?? item.title }
    }

    struct ProjectDetail {
        var project: Project
        var nextActions: [Item]
        var captures: [Item]
        var recentFiles: [(url: URL, mtime: Date)]
        var dirURL: URL
    }

    func reload() {
        all = AppDatabase.shared.activeProjects()
        keys = Dictionary(uniqueKeysWithValues: all.compactMap { p in
            p.id.map { ($0, SearchKey(p.name)) }
        })
        filter()
        reloadGTD()
        if let d = detail { open(project: d.project) }
        IslandController.shared.refresh()   // 状态灯同步
    }

    func reloadGTD() {
        inbox = AppDatabase.shared.inboxCaptures()
        inboxEntries = inbox.map { item in
            var draft: OpenAIClient.ClarifyDraft? = nil
            if let s = item.summary, let data = s.data(using: .utf8) {
                draft = try? JSONDecoder().decode(OpenAIClient.ClarifyDraft.self, from: data)
            }
            return InboxEntry(item: item, draft: draft)
        }
        doneToday = AppDatabase.shared.doneTodayCount()

        nextActions = rows(from: AppDatabase.shared.globalNextActions())
        waiting = rows(from: AppDatabase.shared.items(inList: "waiting"))
        someday = rows(from: AppDatabase.shared.items(inList: "someday"))
        doneRecent = rows(from: AppDatabase.shared.doneItems(days: 7))

        var q: [[ActionRow]] = [[], [], [], []]
        for r in nextActions {
            let imp = (r.item.importance ?? 0) >= 1
            let urg = (r.item.urgency ?? 0) >= 1
            switch (imp, urg) {
            case (true, true): q[0].append(r)
            case (true, false): q[1].append(r)
            case (false, true): q[2].append(r)
            case (false, false): q[3].append(r)
            }
        }
        quadrants = q
    }

    private func rows(from items: [Item]) -> [ActionRow] {
        let names = AppDatabase.shared.projectNames(forItems: items.compactMap(\.id))
        return items.map { ActionRow(item: $0, projectName: $0.id.flatMap { names[$0] }) }
    }

    func project(named name: String) -> Project? {
        all.first { $0.name == name }
    }

    /// 给任意待办设置/修改/清除提醒
    func setRemind(_ item: Item, to date: Date?) {
        guard let id = item.id else { return }
        AppDatabase.shared.setRemind(id, at: date)
        reload()
        if let d = date {
            ToastManager.shared.show("⏰ 已设提醒:\(DateMention.format(d))", duration: 2)
        }
    }

    /// 重命名项目(目录 + DB 同步)
    func renameProject(_ p: Project, to newName: String) {
        guard let pid = p.id else { return }
        if ProjectLifecycle.rename(p, to: newName) != nil {
            reload()
            if let updated = AppDatabase.shared.project(byId: pid) { open(project: updated) }
            ToastManager.shared.show("✓ 已重命名为「\(newName)」,目录已同步", duration: 2.5)
        } else {
            ToastManager.shared.show("⚠️ 重命名失败:名称无效或已存在同名目录", duration: 3)
        }
    }

    /// 采纳单条 AI 草稿(一键理清,零表单)
    func adopt(_ e: InboxEntry) {
        guard let d = e.draft, let id = e.item.id else { return }
        let pid = all.first { $0.path == d.projectPath }?.id
        var remind: Date? = nil
        if !d.remindDate.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            remind = f.date(from: d.remindDate)
        }
        AppDatabase.shared.applyClarify(
            itemId: id, isActionable: d.isActionable,
            nextAction: d.isActionable && !d.nextAction.isEmpty ? d.nextAction : nil,
            projectId: pid,
            importance: d.important ? 1 : 0, urgency: d.urgent ? 1 : 0,
            list: d.isActionable ? d.list : "someday",
            expectedOutcome: d.expectedOutcome.isEmpty ? nil : d.expectedOutcome,
            waitingFor: d.list == "waiting" && !d.waitingFor.isEmpty ? d.waitingFor : nil,
            remindAt: remind ?? e.item.remindAt)
        Telemetry.record(event: "clarify_adopt", itemId: id,
                         chosenPath: d.isActionable ? d.list : "someday", usedCloud: true)
    }

    /// 一键采纳全部草稿
    func adoptAll() {
        let ready = inboxEntries.filter { $0.draft != nil }
        guard !ready.isEmpty else { return }
        for e in ready { adopt(e) }
        MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 一键采纳 \(ready.count) 条 AI 理清草稿")
        reload()
        ToastManager.shared.show("✓ 已采纳 \(ready.count) 条草稿,行动已就位——收件箱清爽了", duration: 3.5)
    }

    /// 项目完结流转(PARA):status=done + 目录移入 4-Archive/YYYY-Qn/
    func archiveProject(_ p: Project) {
        if let newPath = ProjectLifecycle.archive(p) {
            detail = nil
            reload()
            ToastManager.shared.show("🎉 项目「\(p.name)」已完结,归档到 \(newPath)", duration: 4)
        } else {
            ToastManager.shared.show("归档目录移动失败,项目未变更", duration: 4)
        }
    }

    /// 当前清单页的行数(键盘选择边界)
    var listRowCount: Int {
        switch tab {
        case .inbox: return inbox.count
        case .action: return nextActions.count
        case .waiting: return waiting.count
        case .someday: return someday.count
        case .done: return doneRecent.count
        default: return 0
        }
    }

    /// 清单页 ↵ 的主操作:收件箱 = 理清选中行;行动/等待/搁置 = 完成选中行
    func primaryAction() {
        switch tab {
        case .inbox:
            guard inbox.indices.contains(listSelection) else { return }
            ClarifyController.shared.present(single: inbox[listSelection]) { [weak self] in self?.reload() }
        case .action, .waiting, .someday:
            let rows = tab == .action ? nextActions : (tab == .waiting ? waiting : someday)
            guard rows.indices.contains(listSelection) else { return }
            markDone(rows[listSelection])
            listSelection = min(listSelection, max(0, listRowCount - 1))
        default:
            break
        }
    }

    /// 完成行动:若是行动链上的步骤,toast 提示解锁的下一步
    func markDone(_ row: ActionRow) {
        guard let id = row.item.id else { return }
        AppDatabase.shared.markItemDone(id)
        Telemetry.record(event: "done", itemId: id)
        if let name = row.projectName {
            MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 完成「\(row.text.prefix(40))」(项目:\(name))")
        }
        if let next = AppDatabase.shared.unlockedStep(afterDone: row.item) {
            ToastManager.shared.show("✓ 已完成 · 解锁下一步:「\((next.nextAction ?? next.title).prefix(22))」", duration: 3.5)
        }
        reload()
    }

    func move(_ row: ActionRow, to list: GTDList) {
        guard let id = row.item.id else { return }
        AppDatabase.shared.moveItem(id, toList: list.rawValue)
        reload()
    }

    private func filter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            results = all
        } else {
            results = all
                .map { ($0, $0.id.flatMap { keys[$0] }.map { FuzzyMatcher.score(query: q, key: $0) } ?? 0) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        selectedIndex = 0
    }

    func open(project: Project) {
        guard let pid = project.id else { return }
        let dir = ParaTree.root.appendingPathComponent(project.path)
        detail = ProjectDetail(
            project: AppDatabase.shared.project(byId: pid) ?? project,
            nextActions: AppDatabase.shared.nextActions(projectId: pid, limit: 6),
            captures: AppDatabase.shared.unprocessedCaptures(projectId: pid),
            recentFiles: ParaTree.recentFiles(in: dir, limit: 5),
            dirURL: dir)
    }
}

// MARK: - 主视图

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    let onClose: () -> Void
    let onStartFocus: (Project) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.detail {
                ProjectDetailView(detail: detail, model: model,
                                  onBack: { model.detail = nil },
                                  onStartFocus: onStartFocus)
            } else {
                topBar
                tabBar
                Divider().padding(.horizontal, 14)
                content
            }
        }
        .panelChrome(width: 840)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            IconBadge(systemName: "square.grid.2x2.fill", color: Theme.accent, size: 32)
            TextField("搜索项目(拼音首字母即可)…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            if model.doneToday > 0 {
                // GTD:把「处理完的事」放在醒目位置
                TagChip(text: "今天已完成 \(model.doneToday) 件 🎉", color: Theme.success)
                    .hoverLift(scale: 1.08)
                    .onTapGesture { model.tab = .done }
            }
            Text("esc 关闭").font(Theme.fontCaption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .onAppear { searchFocused = true }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(WorkbenchController.Tab.allCases.enumerated()), id: \.element) { idx, tab in
                tabButton(tab, index: idx)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    /// 彩色胶囊标签页:选中 = 实底色 + 白字,悬停浮起
    private func tabButton(_ tab: WorkbenchController.Tab, index: Int) -> some View {
        let selected = model.tab == tab
        let badge: Int? = {
            switch tab {
            case .inbox: return model.inbox.isEmpty ? nil : model.inbox.count
            case .action: return model.nextActions.isEmpty ? nil : model.nextActions.count
            case .waiting: return model.waiting.isEmpty ? nil : model.waiting.count
            case .someday: return model.someday.isEmpty ? nil : model.someday.count
            default: return nil
            }
        }()
        return Hoverable { hovering in
            Button {
                model.tab = tab
                Telemetry.record(event: "workbench_tab", chosenPath: tab.rawValue)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tab.icon).font(.system(size: 13))
                    Text(tab.name).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    if let b = badge {
                        Text("\(b)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.25) : tab.color.opacity(0.8)))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(selected
                    ? AnyShapeStyle(tab.color.gradient)
                    : AnyShapeStyle(tab.color.opacity(hovering ? 0.14 : 0.06))))
                .foregroundStyle(selected ? .white : (hovering ? tab.color : .secondary))
                .scaleEffect(hovering && !selected ? 1.06 : 1)
                .shadow(color: tab.color.opacity(selected ? 0.35 : 0), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("⌘\(index + 1)")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.query.isEmpty {
            searchResults
            footerHints
        } else {
            Group {
                switch model.tab {
                case .overview: overview
                case .inbox: inboxList
                case .action: actionListPage
                case .waiting: listPage(rows: model.waiting, list: .waiting, extra: nil)
                case .someday: listPage(rows: model.someday, list: .someday, extra: nil)
                case .done: donePage
                case .stats: statsPage
                }
            }
            footerHints
        }
    }

    /// 底部快捷键提示条:工作台是键盘驱动的操作中枢
    private var footerHints: some View {
        HStack(spacing: 12) {
            KeyHint(key: "⌘1-7", label: "切页")
            KeyHint(key: "↑↓", label: "选择")
            KeyHint(key: "↵", label: model.tab == .inbox ? "理清" : (model.tab == .overview || !model.query.isEmpty ? "打开项目" : "完成"))
            KeyHint(key: "esc", label: "关闭")
            Spacer()
            KeyHint(key: "⌥⌘N", label: "捕获")
            KeyHint(key: "⌥⌘I", label: "理清")
            KeyHint(key: "⌥⌘A", label: "归档")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: 总览

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 待办永远在第一屏最显眼的位置(GTD:回答「现在干什么」)
                nextActionsHero
                if !model.inbox.isEmpty { inboxBanner }
                gtdFlowStrip
                if model.doneToday > 0 { doneCelebration }
                projectsSection
            }
            .padding(16)
        }
        .frame(maxHeight: 560)
    }

    /// 置顶待办清单:大字号、完成圈、悬停可直接进聚焦
    private var nextActionsHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("现在该做什么", systemImage: "bolt.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                if model.nextActions.count > 6 {
                    Button("全部 \(model.nextActions.count) 条 →") { model.tab = .action }
                        .buttonStyle(.plain).font(Theme.fontCaption).foregroundStyle(Theme.accent)
                }
            }
            if model.nextActions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18)).foregroundStyle(Theme.success.opacity(0.6))
                    Text(model.inbox.isEmpty
                         ? "行动清单是空的。⌥⌘N 捕获想法,或对项目做 AI 拆解"
                         : "先理清收件箱 ↓,行动会出现在这里")
                        .font(Theme.fontSub).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(model.nextActions.prefix(6)) { row in heroActionRow(row) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.15), lineWidth: 1))
    }

    private func heroActionRow(_ row: WorkbenchModel.ActionRow) -> some View {
        Hoverable { hovering in
            HStack(spacing: 10) {
                doneCircle(row: row, size: 17, color: Theme.accent)
                if let s = row.item.seq {
                    Text("\(s)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Theme.accent.opacity(0.15)))
                        .foregroundStyle(Theme.accent)
                }
                Text(row.text)
                    .font(.system(size: 14.5, weight: hovering ? .medium : .regular))
                    .lineLimit(1)
                RemindChipEditor(remindAt: row.item.remindAt, showPlusWhenEmpty: hovering) { date in
                    model.setRemind(row.item, to: date)
                }
                priorityBadge(row.item)
                Spacer(minLength: 0)
                if let name = row.projectName {
                    if hovering, let proj = model.project(named: name) {
                        Button {
                            onStartFocus(proj)
                        } label: {
                            Label("聚焦做这件", systemImage: "play.fill")
                                .font(Theme.fontCaption)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.mini).tint(Theme.success)
                    } else {
                        TagChip(text: name, color: Theme.accent)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(hovering ? 0.08 : 0)))
        }
    }

    /// GTD 四步动线:收集→理清→组织→执行。每一步都可以直接点进去,是操作入口而非摆设
    private var gtdFlowStrip: some View {
        HStack(spacing: 2) {
            flowStep("tray.and.arrow.down.fill", "收集", "⌥⌘N 随手记", count: nil,
                     color: Theme.warning, active: true) {
                onClose(); AppActions.capture()
            }
            flowArrow
            flowStep("wand.and.stars", "理清", model.inbox.isEmpty ? "已清空 ✓" : "\(model.inbox.count) 条待理清",
                     count: model.inbox.count, color: Theme.violet, active: !model.inbox.isEmpty) {
                if model.inbox.isEmpty { model.tab = .inbox }
                else { ClarifyController.shared.startQueue { [weak model] in model?.reload() } }
            }
            flowArrow
            flowStep("square.grid.2x2.fill", "组织", "\(model.nextActions.count) 条行动", count: nil,
                     color: Theme.accent, active: !model.nextActions.isEmpty) {
                model.tab = .action
            }
            flowArrow
            flowStep("timer", "执行", FocusManager.shared.isActive ? "聚焦中…" : "选项目进聚焦", count: nil,
                     color: Theme.success, active: FocusManager.shared.isActive) {
                if let first = model.results.first { model.open(project: first) }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
    }

    private func flowStep(_ icon: String, _ name: String, _ sub: String, count: Int?,
                          color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Hoverable { hovering in
            Button(action: action) {
                VStack(spacing: 4) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: icon)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(active || hovering ? color : .secondary)
                            .frame(width: 32, height: 26)
                            .symbolEffect(.bounce, value: hovering)
                        if let c = count, c > 0 {
                            Text("\(min(c, 99))")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(.red))
                                .offset(x: 9, y: -5)
                        }
                    }
                    Text(name).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(hovering ? color : .primary)
                    Text(hovering ? "点击进入 →" : sub)
                        .font(Theme.fontMicro)
                        .foregroundStyle(hovering ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(hovering ? 0.1 : 0)))
                .scaleEffect(hovering ? 1.05 : 1)
            }
            .buttonStyle(.plain)
        }
    }

    private var flowArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.quaternary)
    }

    /// 醒目的「已处理完」区(GTD:完成的事放显眼处,给正反馈)
    private var doneCelebration: some View {
        HStack(spacing: 10) {
            IconBadge(systemName: "checkmark.seal.fill", color: Theme.success, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("今天已完成 \(model.doneToday) 件事 🎉").font(.system(size: 13, weight: .semibold))
                if let last = model.doneRecent.first {
                    Text("最近:「\(last.text.prefix(24))」").font(Theme.fontCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("查看全部") { model.tab = .done }.controlSize(.mini)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.success.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.success.opacity(0.25), lineWidth: 1))
    }

    private var inboxBanner: some View {
        HStack(spacing: 10) {
            IconBadge(systemName: "tray.full.fill", color: Theme.warning, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("收件箱有 \(model.inbox.count) 条待理清").font(.system(size: 12.5, weight: .medium))
                Text(model.inbox.prefix(2).map { "「\($0.title.prefix(14))」" }.joined(separator: " "))
                    .font(Theme.fontCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                ClarifyController.shared.startQueue { [weak model] in model?.reload() }
            } label: { Label("开始理清", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.warning)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warning.opacity(0.25), lineWidth: 1))
    }

    private var matrixGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("square.grid.2x2.fill", "艾森豪威尔矩阵", Theme.violet)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                quadrantBox(0, "重要 · 紧急", "现在就做", Theme.danger)
                quadrantBox(1, "重要 · 不紧急", "排进计划", Theme.accent)
                quadrantBox(2, "紧急 · 不重要", "尽快搞定", Theme.warning)
                quadrantBox(3, "不重要 · 不紧急", "考虑丢弃", .gray)
            }
        }
    }

    private func quadrantBox(_ idx: Int, _ title: String, _ hint: String, _ color: Color) -> some View {
        let rows = model.quadrants[idx]
        return Hoverable { hovering in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                    Text(rows.isEmpty ? hint : (hovering ? "查看全部 →" : "\(rows.count)"))
                        .font(Theme.fontMicro)
                        .foregroundStyle(hovering ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                }
                if rows.isEmpty {
                    Text("—").font(Theme.fontSub).foregroundStyle(.quaternary)
                } else {
                    ForEach(rows.prefix(3)) { row in actionLine(row, compact: true) }
                    if rows.count > 3 {
                        Text("还有 \(rows.count - 3) 条…").font(Theme.fontMicro).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 11).fill(color.opacity(hovering ? 0.1 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(color.opacity(hovering ? 0.4 : 0.18), lineWidth: 1))
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: color.opacity(hovering ? 0.15 : 0), radius: 8, y: 3)
            .contentShape(Rectangle())
            .onTapGesture { model.tab = .action }
        }
    }

    private var nextActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("bolt.fill", "下一步行动(全部项目汇总)", Theme.accent)
                Spacer()
                if !model.nextActions.isEmpty {
                    Button("全部 \(model.nextActions.count) 条") { model.tab = .action }.controlSize(.mini)
                }
            }
            if model.nextActions.isEmpty {
                Text(model.inbox.isEmpty
                     ? "暂无。⌥⌘N 捕获想法,理清后会出现在这里"
                     : "先把收件箱理清,行动就会出现在这里 ↑")
                    .font(Theme.fontSub).foregroundStyle(.tertiary)
            } else {
                ForEach(model.nextActions.prefix(5)) { row in actionLine(row, compact: false) }
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionHeader("folder.fill", "项目(↑↓ 选择 ↵ 打开)", Theme.teal)
                Spacer()
                Button {
                    NewProjectController.shared.present { [weak model] _ in model?.reload() }
                } label: { Label("新建", systemImage: "plus") }
                    .controlSize(.mini)
                    .help("应用内直接建项目/领域,目录自动创建并绑定(⌘N)")
            }
            if model.results.isEmpty {
                Text("还没有项目。点右上「新建」,或归档文件时在面板里顺手建")
                    .font(Theme.fontSub).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(model.results.prefix(6).enumerated()), id: \.element.path) { idx, p in
                    projectRow(p, selected: idx == model.selectedIndex, index: idx)
                }
            }
        }
    }

    // MARK: 清单页

    private var inboxList: some View {
        VStack(spacing: 0) {
            listUsageHeader(icon: "tray.fill", color: Theme.warning,
                            text: "一切想法先进这里,不做判断。定期清空:逐条理清成任务或想法,系统才可信。")
            if model.inbox.isEmpty {
                emptyPage("收件箱已清空", "Inbox Zero ✓ 有想法随时 ⌥⌘N")
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(spacing: 3) {
                            ForEach(Array(model.inboxEntries.enumerated()), id: \.element.id) { idx, entry in
                                inboxRow(entry, selected: idx == model.listSelection, index: idx)
                                    .id(entry.id)
                            }
                        }
                        .onChange(of: model.listSelection) { _, v in
                            if model.inboxEntries.indices.contains(v) {
                                withAnimation { proxy.scrollTo(model.inboxEntries[v].id, anchor: .center) }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 470)
                HStack {
                    let draftCount = model.inboxEntries.filter { $0.draft != nil }.count
                    if draftCount > 0 {
                        Button {
                            model.adoptAll()
                        } label: { Label("一键采纳全部草稿(\(draftCount))", systemImage: "checkmark.seal.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.success)
                    }
                    Spacer()
                    Button {
                        ClarifyController.shared.startQueue { [weak model] in model?.reload() }
                    } label: { Label("逐条理清(\(model.inbox.count))", systemImage: "wand.and.stars") }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private func inboxRow(_ entry: WorkbenchModel.InboxEntry, selected: Bool, index: Int) -> some View {
        let item = entry.item
        return HStack(spacing: 10) {
            Image(systemName: item.type == "link" ? "link" : "lightbulb.fill")
                .font(.system(size: 14)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: selected ? .medium : .regular)).lineLimit(1)
                if let summary = entry.draftSummary {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Theme.violet)
                        Text(summary).font(Theme.fontMicro).foregroundStyle(Theme.violet).lineLimit(1)
                    }
                } else {
                    Text(WorkbenchView.relative(item.createdAt) + (item.source.map { " · 来自 \($0)" } ?? ""))
                        .font(Theme.fontMicro).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let r = item.remindAt { TagChip(text: "⏰ \(DateMention.format(r))", color: Theme.warning) }
            if entry.draft != nil {
                Button {
                    model.adopt(entry)
                    model.reload()
                    ToastManager.shared.show("✓ 已采纳草稿", duration: 1.5)
                } label: { Label("采纳", systemImage: "checkmark") }
                    .controlSize(.small).tint(Theme.success)
                    .opacity(selected ? 1 : 0.6)
            }
            Button(entry.draft != nil ? "细看" : (selected ? "理清 ↵" : "理清")) {
                ClarifyController.shared.present(single: item) { [weak model] in model?.reload() }
            }
            .controlSize(.small)
            .tint(Theme.violet)
            .opacity(selected ? 1 : 0.5)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Theme.warning.opacity(0.08) : Color.secondary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Theme.warning.opacity(0.4) : .clear, lineWidth: 1))
        .scaleEffect(selected ? 1.008 : 1)
        .animation(.spring(duration: 0.2), value: selected)
        .contentShape(Rectangle())
        .onHover { if $0 { model.listSelection = index } }
    }

    /// 行动页:矩阵(组织视图)在上,全局行动清单在下
    private var actionListPage: some View {
        VStack(spacing: 0) {
            listUsageHeader(icon: GTDList.action.icon, color: GTDList.action.color, text: GTDList.action.usage)
            if model.nextActions.isEmpty {
                emptyPage("行动清单是空的", "理清收件箱或 AI 拆解项目任务后,行动会出现在这里")
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 12) {
                            matrixGrid
                            VStack(spacing: 3) {
                                ForEach(Array(model.nextActions.enumerated()), id: \.element.id) { idx, row in
                                    listRow(row, list: .action, selected: idx == model.listSelection, index: idx)
                                        .id(row.id)
                                }
                            }
                            if let extra = actionExtras { extra }
                        }
                        .onChange(of: model.listSelection) { _, v in
                            if model.nextActions.indices.contains(v) {
                                withAnimation { proxy.scrollTo(model.nextActions[v].id, anchor: .center) }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 500)
            }
        }
    }

    private var actionExtras: AnyView? {
        model.nextActions.contains { $0.item.seq != nil }
            ? AnyView(Text("⛓ 带编号的是项目行动链:完成当前步会自动解锁下一步")
                .font(Theme.fontMicro).foregroundStyle(.tertiary))
            : nil
    }

    private func listPage(rows: [WorkbenchModel.ActionRow], list: GTDList, extra: AnyView?) -> some View {
        VStack(spacing: 0) {
            listUsageHeader(icon: list.icon, color: list.color, text: list.usage)
            if rows.isEmpty {
                emptyPage("\(list.name)清单是空的", list == .action ? "理清收件箱或 AI 拆解项目任务后,行动会出现在这里" : "理清时选择「\(list.name)」即可归入")
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(spacing: 3) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                                listRow(row, list: list, selected: idx == model.listSelection, index: idx)
                                    .id(row.id)
                            }
                            if let extra { extra.padding(.top, 6) }
                        }
                        .onChange(of: model.listSelection) { _, v in
                            if rows.indices.contains(v) {
                                withAnimation { proxy.scrollTo(rows[v].id, anchor: .center) }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 500)
            }
        }
    }

    private func listRow(_ row: WorkbenchModel.ActionRow, list: GTDList, selected: Bool, index: Int) -> some View {
        HStack(spacing: 10) {
            doneCircle(row: row, size: 16, color: list.color)
            if let s = row.item.seq {
                Text("\(s)")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(Theme.accent.opacity(0.15)))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let o = row.item.expectedOutcome, !o.isEmpty {
                        Text("→ \(o)").font(Theme.fontMicro).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if list == .waiting, let w = row.item.waitingFor, !w.isEmpty {
                        Text("在等:\(w)").font(Theme.fontMicro).foregroundStyle(Theme.teal)
                    }
                }
            }
            Spacer()
            if list == .waiting {
                let days = Calendar.current.dateComponents([.day], from: row.item.updatedAt, to: Date()).day ?? 0
                if days >= 1 {
                    TagChip(text: "已等 \(days) 天", color: days >= 3 ? Theme.danger : Theme.teal)
                }
            }
            RemindChipEditor(remindAt: row.item.remindAt, showPlusWhenEmpty: selected) { date in
                model.setRemind(row.item, to: date)
            }
            if let name = row.projectName { TagChip(text: name, color: Theme.accent) }
            priorityBadge(row.item)
            moveMenu(row, current: list)
                .opacity(selected ? 1 : 0.25)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? list.color.opacity(0.1) : Color.secondary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? list.color.opacity(0.4) : .clear, lineWidth: 1))
        .scaleEffect(selected ? 1.008 : 1)
        .animation(.spring(duration: 0.2), value: selected)
        .contentShape(Rectangle())
        .onHover { if $0 { model.listSelection = index } }
    }

    // MARK: 统计页(埋点数据分析)

    private var statsPage: some View {
        let a = Telemetry.analytics()
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // GTD 漏斗:捕获 → 理清 → 完成
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("chart.bar.fill", "GTD 漏斗(想法都去哪了)", Theme.accent)
                    funnelBar("捕获", a.captured, max: a.captured, color: Theme.warning)
                    funnelBar("已理清", a.clarified, max: a.captured, color: Theme.accent,
                              note: "理清率 \(a.clarifyRate)%")
                    funnelBar("已完成", a.doneTotal, max: a.captured, color: Theme.success,
                              note: "完成率 \(a.doneRate)%")
                    if a.dropped > 0 {
                        Text("另有 \(a.dropped) 条理清时果断丢弃——丢弃也是生产力")
                            .font(Theme.fontMicro).foregroundStyle(.tertiary)
                    }
                }
                // 关键行为率
                HStack(spacing: 8) {
                    statCard("\(a.twoMin)", "两分钟立即做", Theme.warning, sub: "占捕获 \(a.twoMinRate)%")
                    statCard("\(a.done7)", "近 7 天完成", Theme.success, sub: nil)
                    statCard("\(a.planSaved)", "AI 拆解次数", Theme.violet, sub: nil)
                    statCard("\(a.remindFired)", "提醒触发", Theme.teal, sub: nil)
                }
                // 清单存量
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("tray.2.fill", "清单存量(越少越健康)", Theme.teal)
                    HStack(spacing: 8) {
                        statCard("\(a.inboxNow)", "收件箱", a.inboxNow > 5 ? Theme.danger : Theme.warning, sub: nil)
                        statCard("\(a.actionNow)", "行动", Theme.accent, sub: nil)
                        statCard("\(a.waitingNow)", "等待", Theme.teal, sub: nil)
                        statCard("\(a.somedayNow)", "搁置", .gray, sub: nil)
                    }
                }
                // 归档指标(P0 验收口径;平均耗时无意义已移除)
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("archivebox.fill", "文件归档", Theme.violet)
                    HStack(spacing: 10) {
                        statCard("\(a.archiveTotal)", "归档总数", Theme.violet, sub: nil)
                        statCard("\(a.hitRate)%", "首选命中率", a.hitRate >= 70 ? Theme.success : Theme.warning,
                                 sub: "验收 >70%")
                        statCard("\(a.fallbackCount)", "搜索兜底", Theme.warning, sub: "AI 没猜中的次数")
                        statCard("\(a.cloudPct)%", "云端调用", Theme.teal, sub: "应随使用下降")
                    }
                    Text("top-3 命中 \(a.ranked) 次 · 记忆 \(a.memoryCount) 条(越用越准)")
                        .font(Theme.fontMicro).foregroundStyle(.tertiary)
                }
                HStack {
                    Spacer()
                    Button {
                        ReviewPanelController.shared.present()
                    } label: { Label("开始每周复盘", systemImage: "sparkle.magnifyingglass") }
                        .controlSize(.small)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 540)
    }

    private func funnelBar(_ label: String, _ value: Int, max: Int, color: Color, note: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.fontSub).frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.1))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.gradient)
                        .frame(width: max > 0 ? geo.size.width * CGFloat(value) / CGFloat(max) : 0)
                }
            }
            .frame(height: 18)
            Text("\(value)").font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(color).frame(width: 34, alignment: .trailing)
            if let n = note {
                Text(n).font(Theme.fontMicro).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            }
        }
    }

    private func statCard(_ num: String, _ label: String, _ color: Color, sub: String?) -> some View {
        Hoverable { hovering in
            VStack(spacing: 3) {
                Text(num).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(color)
                Text(label).font(Theme.fontCaption).foregroundStyle(.secondary)
                if let s = sub {
                    Text(s).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(hovering ? 0.13 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(hovering ? 0.35 : 0), lineWidth: 1))
            .scaleEffect(hovering ? 1.04 : 1)
            .shadow(color: color.opacity(hovering ? 0.2 : 0), radius: 8, y: 3)
        }
    }

    /// 移动到其他清单 / 沉淀为资源
    private func moveMenu(_ row: WorkbenchModel.ActionRow, current: GTDList) -> some View {
        Menu {
            ForEach(GTDList.allCases.filter { $0 != current }) { l in
                Button {
                    model.move(row, to: l)
                } label: { Label("移到\(l.name)", systemImage: l.icon) }
            }
            if current == .someday {
                Divider()
                Button {
                    if ResourceSink.sink(item: row.item) != nil {
                        model.reload()
                        ToastManager.shared.show("已沉淀到 3-Resources/灵感笔记 📚", duration: 2.5)
                    }
                } label: { Label("沉淀为资源(存为 md)", systemImage: "books.vertical") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
    }

    private var donePage: some View {
        VStack(spacing: 0) {
            listUsageHeader(icon: "checkmark.seal.fill", color: Theme.success,
                            text: "近 7 天处理完的事。GTD 的意义就是这里不断变长——每周复盘时回看。")
            if model.doneRecent.isEmpty {
                emptyPage("最近还没有完成记录", "在行动清单里勾掉第一件事吧")
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.doneRecent) { row in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13)).foregroundStyle(Theme.success)
                                Text(row.text).font(Theme.fontBody).strikethrough(color: .secondary)
                                    .foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if let name = row.projectName { TagChip(text: name, color: .secondary) }
                                if let t = row.item.completedAt {
                                    Text(WorkbenchView.relative(t)).font(Theme.fontMicro).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 500)
            }
        }
    }

    private func listUsageHeader(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
            Text(text).font(Theme.fontCaption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(color.opacity(0.05))
    }

    private func emptyPage(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: model.tab.icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(model.tab.color.opacity(0.35))
                .padding(.bottom, 2)
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            Text(sub).font(Theme.fontSub).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 56)
    }

    // MARK: 共用小件

    /// 完成圈:悬停即变绿色对勾预览,点下去有确定感
    private func doneCircle(row: WorkbenchModel.ActionRow, size: CGFloat, color: Color) -> some View {
        Hoverable { hovering in
            Button { model.markDone(row) } label: {
                Image(systemName: hovering ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: size))
                    .foregroundStyle(hovering ? Theme.success : color)
                    .scaleEffect(hovering ? 1.25 : 1)
            }
            .buttonStyle(.plain)
            .help("标记完成(↵)")
        }
    }

    private func actionLine(_ row: WorkbenchModel.ActionRow, compact: Bool) -> some View {
        Hoverable { hovering in
            HStack(spacing: 8) {
                doneCircle(row: row, size: compact ? 12 : 15, color: .secondary)
                if !compact, let s = row.item.seq {
                    Text("\(s)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Theme.accent.opacity(0.15)))
                        .foregroundStyle(Theme.accent)
                }
                Text(row.text)
                    .font(.system(size: compact ? 12 : 13.5, weight: hovering ? .medium : .regular))
                    .lineLimit(1)
                if !compact, let name = row.projectName { TagChip(text: name, color: Theme.accent) }
                if !compact, let r = row.item.remindAt {
                    TagChip(text: "⏰ \(DateMention.format(r))", color: r < Date() ? Theme.danger : Theme.warning)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, compact ? 1 : 3)
            .padding(.horizontal, compact ? 0 : 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(hovering && !compact ? 0.06 : 0)))
        }
    }

    private func priorityBadge(_ item: Item) -> some View {
        let imp = (item.importance ?? 0) >= 1
        let urg = (item.urgency ?? 0) >= 1
        return Group {
            if imp || urg {
                TagChip(text: imp && urg ? "重要紧急" : (imp ? "重要" : "紧急"),
                        color: imp && urg ? Theme.danger : (imp ? Theme.accent : Theme.warning))
            }
        }
    }

    private var searchResults: some View {
        VStack(spacing: 2) {
            if model.results.isEmpty {
                VStack(spacing: 10) {
                    emptyPage("无匹配项目", "可以直接创建:")
                    Button {
                        NewProjectController.shared.present(defaultName: model.query) { [weak model] p in
                            model?.query = ""
                            model?.reload()
                            if let p { model?.open(project: p) }
                        }
                    } label: { Label("新建项目「\(model.query)」", systemImage: "folder.badge.plus") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .padding(.bottom, 16)
                }
            } else {
                ForEach(Array(model.results.prefix(8).enumerated()), id: \.element.path) { idx, p in
                    projectRow(p, selected: idx == model.selectedIndex, index: idx)
                }
            }
        }
        .padding(8)
    }

    private func projectRow(_ p: Project, selected: Bool, index: Int) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(selected ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 14, weight: selected ? .medium : .regular))
                if let note = p.lastProgressNote, !note.isEmpty {
                    Text(note).font(Theme.fontCaption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let t = p.lastWorkedAt {
                Text(Self.relative(t)).font(Theme.fontCaption).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary))
                .offset(x: selected ? 2 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.1) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
        .animation(.spring(duration: 0.2), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { model.open(project: p) }
        .onHover { if $0 { model.selectedIndex = index } }
    }

    private func sectionHeader(_ icon: String, _ title: String, _ color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 项目详情

struct ProjectDetailView: View {
    let detail: WorkbenchModel.ProjectDetail
    @ObservedObject var model: WorkbenchModel
    let onBack: () -> Void
    let onStartFocus: (Project) -> Void
    @State private var showDuePicker = false
    @State private var dueDraft = Date()
    @State private var showArchiveConfirm = false
    @State private var showRename = false
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let purpose = detail.project.purpose, !purpose.isEmpty {
                        purposeCard(purpose, outcome: detail.project.outcome)
                    }
                    section("bolt.fill", "下一步行动", Theme.accent) {
                        if detail.nextActions.isEmpty {
                            emptyHint("暂无。捕获想法理清,或用「AI 拆解」生成行动链")
                        } else {
                            ForEach(detail.nextActions, id: \.id) { item in detailActionRow(item) }
                        }
                    }
                    section("clock.arrow.circlepath", "上次做到哪", Theme.teal) {
                        if let note = detail.project.lastProgressNote, !note.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note).font(Theme.fontBody)
                                if let t = detail.project.lastWorkedAt {
                                    Text(WorkbenchView.relative(t)).font(Theme.fontCaption).foregroundStyle(.tertiary)
                                }
                            }
                        } else {
                            emptyHint("还没有记录。结束一次聚焦时写一句,下次就能直接接上")
                        }
                    }
                    section("doc.on.doc", "最近动过的文件", Theme.warning) {
                        if detail.recentFiles.isEmpty {
                            emptyHint("目录还是空的")
                        } else {
                            ForEach(detail.recentFiles, id: \.url) { f in
                                Button {
                                    NSWorkspace.shared.open(f.url)
                                } label: {
                                    HStack {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path))
                                            .resizable().frame(width: 15, height: 15)
                                        Text(f.url.lastPathComponent)
                                            .font(Theme.fontBody).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(WorkbenchView.relative(f.mtime))
                                            .font(Theme.fontCaption).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !detail.captures.isEmpty {
                        section("tray.full", "待消化(\(detail.captures.count))", Theme.violet) {
                            ForEach(detail.captures, id: \.id) { item in
                                HStack(spacing: 7) {
                                    Image(systemName: item.type == "link" ? "link" : "lightbulb")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(item.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button("理清") {
                                        ClarifyController.shared.present(single: item) { [weak model] in
                                            model?.reload()
                                        }
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 440)
            Divider().padding(.horizontal, 14)
            actionBar
        }
    }

    private func detailActionRow(_ item: Item) -> some View {
        HStack(spacing: 7) {
            Button {
                if let id = item.id {
                    AppDatabase.shared.markItemDone(id)
                    Telemetry.record(event: "done", itemId: id)
                    if let next = AppDatabase.shared.unlockedStep(afterDone: item) {
                        ToastManager.shared.show("✓ 解锁下一步:「\((next.nextAction ?? next.title).prefix(22))」", duration: 3)
                    }
                    model.reload()
                }
            } label: {
                Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Theme.success)
            }
            .buttonStyle(.plain).help("标记完成")
            if let s = item.seq {
                Text("\(s)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Theme.accent.opacity(0.15)))
                    .foregroundStyle(Theme.accent)
            }
            Text(item.nextAction ?? item.title).font(Theme.fontBody)
            RemindChipEditor(remindAt: item.remindAt, showPlusWhenEmpty: true) { date in
                if let id = item.id {
                    AppDatabase.shared.setRemind(id, at: date)
                    model.reload()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func purposeCard(_ purpose: String, outcome: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "scope").font(.system(size: 11)).foregroundStyle(Theme.violet)
                Text("目的:\(purpose)").font(Theme.fontSub)
            }
            if let o = outcome, !o.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "flag.checkered").font(.system(size: 11)).foregroundStyle(Theme.success)
                    Text("期望结果:\(o)").font(Theme.fontSub).foregroundStyle(.secondary)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.violet.opacity(0.06)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Text(detail.project.name).font(.system(size: 15, weight: .semibold))
            Button {
                renameDraft = detail.project.name
                showRename = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("重命名项目(目录同步改名)")
            .popover(isPresented: $showRename, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    Text("重命名项目").font(Theme.fontSub).foregroundStyle(.secondary)
                    TextField("新名称", text: $renameDraft)
                        .textFieldStyle(.roundedBorder).font(Theme.fontBody).frame(width: 240)
                        .onSubmit {
                            showRename = false
                            model.renameProject(detail.project, to: renameDraft)
                        }
                    HStack {
                        Text("目录会一并改名").font(Theme.fontMicro).foregroundStyle(.tertiary)
                        Spacer()
                        Button("保存") {
                            showRename = false
                            model.renameProject(detail.project, to: renameDraft)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                .padding(12)
            }
            Spacer()
            dueBadge
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// 截止日期:点击编辑,矩阵「紧急」的客观依据
    private var dueBadge: some View {
        Button {
            dueDraft = detail.project.dueDate
                ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())!
            showDuePicker = true
        } label: {
            if let due = detail.project.dueDate {
                let days = Calendar.current.dateComponents(
                    [.day], from: Calendar.current.startOfDay(for: Date()),
                    to: Calendar.current.startOfDay(for: due)).day ?? 0
                TagChip(text: days >= 0 ? "⏳ 还剩 \(days) 天" : "🔥 已逾期 \(-days) 天",
                        color: days < 3 ? Theme.danger : Theme.accent)
            } else {
                TagChip(text: "＋ 设截止日期", color: .secondary)
            }
        }
        .buttonStyle(.plain)
        .help("设置/修改项目截止日期")
        .popover(isPresented: $showDuePicker, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                DatePicker("", selection: $dueDraft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 240)
                HStack {
                    if detail.project.dueDate != nil {
                        Button("清除") {
                            if let pid = detail.project.id {
                                AppDatabase.shared.setProjectDue(pid, date: nil)
                                model.reload()
                            }
                            showDuePicker = false
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    Button("保存") {
                        if let pid = detail.project.id {
                            AppDatabase.shared.setProjectDue(pid, date: dueDraft)
                            model.reload()
                        }
                        showDuePicker = false
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(12)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(detail.dirURL)
            } label: { Label("Finder", systemImage: "folder") }
            if let recent = detail.recentFiles.first {
                Button {
                    NSWorkspace.shared.open(recent.url)
                } label: { Label("继续上次文件", systemImage: "arrow.uturn.forward") }
            }
            Button {
                PlanController.shared.present(project: detail.project) { [weak model] in
                    model?.reload()
                }
            } label: { Label("AI 拆解", systemImage: "square.stack.3d.up") }
            Button {
                showArchiveConfirm = true
            } label: { Label("完结", systemImage: "flag.checkered") }
                .help("PARA 流转:项目完结,整个目录移入 4-Archive")
                .confirmationDialog("完结项目「\(detail.project.name)」?",
                                    isPresented: $showArchiveConfirm) {
                    Button("完结并移入 4-Archive") { model.archiveProject(detail.project) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("目录将移动到 4-Archive/本季度/,项目从活跃列表消失(文件仍可随时找到)")
                }
            Spacer()
            Button {
                onStartFocus(detail.project)
            } label: { Label("进入聚焦(25 分钟)", systemImage: "timer") }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func section<Content: View>(_ icon: String, _ title: String, _ color: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
            content()
                .padding(.leading, 2)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(Theme.fontSub).foregroundStyle(.tertiary)
    }
}
