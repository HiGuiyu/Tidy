import AppKit
import SwiftUI

/// AI 理清草稿面板(§4.4):把 30 秒决策降为 3 秒确认。
/// 自动区分想法与任务(行动+期望结果),路由到 行动/等待/搁置 清单,
/// 内置 GTD 两分钟规则与时间提及提醒。
@MainActor
final class ClarifyController {
    static let shared = ClarifyController()

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<ClarifyView>?
    private var keyMonitor: Any?
    private var queue: [Item] = []
    private var index = 0
    private var model: ClarifyModel?
    private var aiTask: Task<Void, Never>?

    var aiClient: OpenAIClient?
    private var onFinished: (() -> Void)?

    /// 理清整个收件箱(逐条)
    func startQueue(onFinished: (() -> Void)? = nil) {
        let items = AppDatabase.shared.inboxCaptures()
        guard !items.isEmpty else {
            ToastManager.shared.show("收件箱已清空 ✓ Inbox Zero!", duration: 2.5)
            onFinished?()
            return
        }
        self.onFinished = onFinished
        queue = items
        index = 0
        presentCurrent()
    }

    /// 理清单条
    func present(single item: Item, onFinished: (() -> Void)? = nil) {
        self.onFinished = onFinished
        queue = [item]
        index = 0
        presentCurrent()
    }

    private func presentCurrent() {
        aiTask?.cancel()
        guard index < queue.count else { finish(cleared: true); return }
        let item = queue[index]
        let projects = AppDatabase.shared.activeProjects()
        let m = ClarifyModel(item: item, projects: projects,
                             progress: queue.count > 1 ? "\(index + 1) / \(queue.count)" : nil)
        if let iid = item.id, let name = AppDatabase.shared.projectNames(forItems: [iid])[iid] {
            m.selectedProjectId = projects.first { $0.name == name }?.id
        }
        // 捕获时本地识别到的时间作为默认提醒
        m.remindAt = item.remindAt ?? DateMention.detect(in: item.content ?? item.title)
        model = m

        let view = ClarifyView(model: m,
                               onConfirm: { [weak self] in self?.confirm() },
                               onRefine: { [weak self] in self?.refineWithAnswer() },
                               onTwoMinDone: { [weak self] in self?.twoMinDone() },
                               onDrop: { [weak self] in self?.dropCurrent() },
                               onSkip: { [weak self] in self?.skip() })
        if let hosting {
            hosting.rootView = view
            panel?.setContentSize(hosting.fittingSize)
        } else {
            buildPanel(with: view)
        }
        fillWithAI(m, item: item)
    }

    /// AI 出草稿:捕获时已预理清的直接秒出;否则现场起草(用户动过表单则不打扰)
    private func fillWithAI(_ m: ClarifyModel, item: Item) {
        // 预理清草稿(capture 时后台生成,存在 summary 字段)
        if let cached = item.summary, let data = cached.data(using: .utf8),
           let draft = try? JSONDecoder().decode(OpenAIClient.ClarifyDraft.self, from: data) {
            m.applyDraft(draft, projects: m.projects)
            return
        }
        guard let client = aiClient else { return }
        m.aiLoading = true
        aiTask = Task { [weak self, weak m] in
            do {
                let projects = AppDatabase.shared.activeProjects()
                let draft = try await client.clarify(
                    text: item.content ?? item.title,
                    projectPaths: projects.map(\.path),
                    activeProjectPath: FocusManager.shared.activeProjectPath)
                guard let self, let m, self.model === m, !Task.isCancelled else { return }
                m.aiLoading = false
                guard !m.userEdited else { return }
                m.applyDraft(draft, projects: projects)
            } catch {
                guard let m, !Task.isCancelled else { return }
                m.aiLoading = false
                m.aiReason = "AI 草稿不可用,手动填写即可"
            }
        }
    }

    private func buildPanel(with view: ClarifyView) {
        let h = NSHostingView(rootView: view)
        h.layoutSubtreeIfNeeded()
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: h.fittingSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = h
        p.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - h.fittingSize.width / 2, y: f.minY + f.height * 0.82))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
        hosting = h

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow,
                  !panel.imeComposing else { return event }
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 53: self.finish(cleared: false); return nil        // esc
            case 36, 76: self.confirm(); return nil                 // ↵
            case 51 where cmd: self.dropCurrent(); return nil       // ⌘⌫ 丢弃
            case 124 where cmd: self.skip(); return nil             // ⌘→ 跳过
            case 17 where cmd: self.twoMinDone(); return nil        // ⌘T 两分钟已做完
            default: return event
            }
        }
    }

    // MARK: - 动作

    private func confirm() {
        guard let m = model, let itemId = m.item.id else { return }
        // 不可执行 + 选了沉淀:直接落 3-Resources,不走清单
        if !m.isActionable, m.ideaDestination == .resource {
            if ResourceSink.sink(item: m.item) != nil {
                ToastManager.shared.show("已沉淀到 3-Resources/灵感笔记 📚", duration: 2.5)
            }
            index += 1
            presentCurrent()
            return
        }
        AppDatabase.shared.applyClarify(
            itemId: itemId,
            isActionable: m.isActionable,
            nextAction: m.isActionable && !m.nextAction.isEmpty ? m.nextAction : nil,
            projectId: m.selectedProjectId,
            importance: m.important ? 1 : 0,
            urgency: m.urgent ? 1 : 0,
            list: m.isActionable ? m.list.rawValue : "someday",
            expectedOutcome: m.expectedOutcome.isEmpty ? nil : m.expectedOutcome,
            waitingFor: m.list == .waiting && !m.waitingFor.isEmpty ? m.waitingFor : nil,
            remindAt: m.remindAt)
        Telemetry.record(event: "clarify", itemId: itemId,
                         chosenPath: m.isActionable ? m.list.rawValue : "someday",
                         latencyMs: Int(Date().timeIntervalSince(m.shownAt) * 1000),
                         usedCloud: m.aiFilled)
        let proj = m.projects.first { $0.id == m.selectedProjectId }
        if m.isActionable, !m.nextAction.isEmpty {
            MemoryStore.shared.recordEpisodic(
                "\(Archiver.dateStr()) 理清「\(m.item.title.prefix(30))」→ \(m.list.name):\(m.nextAction.prefix(40))" +
                (proj.map { ",项目:\($0.name)" } ?? ""))
        }
        index += 1
        presentCurrent()
    }

    /// GTD 两分钟规则:2 分钟内解决 → 立即做完,直接标记 done
    private func twoMinDone() {
        guard let m = model, let itemId = m.item.id else { return }
        AppDatabase.shared.applyClarify(itemId: itemId, isActionable: true,
                                        nextAction: m.nextAction.isEmpty ? m.item.title : m.nextAction,
                                        projectId: m.selectedProjectId, importance: 0, urgency: 1)
        AppDatabase.shared.markItemDone(itemId)
        Telemetry.record(event: "two_min_done", itemId: itemId, usedCloud: m.aiFilled)
        ToastManager.shared.show("⚡ 两分钟规则:已完成「\(m.item.title.prefix(16))」", duration: 2)
        index += 1
        presentCurrent()
    }

    private func dropCurrent() {
        guard let m = model, let itemId = m.item.id else { return }
        AppDatabase.shared.dropItem(itemId)
        Telemetry.record(event: "clarify_drop", itemId: itemId)
        index += 1
        presentCurrent()
    }

    private func skip() {
        if let id = model?.item.id { Telemetry.record(event: "clarify_skip", itemId: id) }
        index += 1
        presentCurrent()
    }

    /// 子面板(如新建项目)关闭后把键盘焦点还给理清面板
    func refocus() {
        panel?.makeKeyAndOrderFront(nil)
    }

    /// 把用户对关键问题的回答交回 AI,重新起草整份草稿
    func refineWithAnswer() {
        guard let m = model, let client = aiClient, let itemId = m.item.id else { return }
        let answer = m.questionAnswer.trimmingCharacters(in: .whitespaces)
        guard !answer.isEmpty else { return }
        let combined = (m.item.content ?? m.item.title) + "\n(补充说明:\(answer))"
        // 回答沉淀进条目正文,后续查看/再理清都带着上下文
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET content = ?, updatedAt = ? WHERE id = ?",
                           arguments: [combined, Date(), itemId])
        }
        Telemetry.record(event: "clarify_refine", itemId: itemId)
        m.aiQuestion = nil
        m.questionAnswer = ""
        m.userEdited = false
        m.aiLoading = true
        aiTask?.cancel()
        aiTask = Task { [weak self, weak m] in
            do {
                let projects = AppDatabase.shared.activeProjects()
                let draft = try await client.clarify(
                    text: combined,
                    projectPaths: projects.map(\.path),
                    activeProjectPath: FocusManager.shared.activeProjectPath)
                guard let self, let m, self.model === m, !Task.isCancelled else { return }
                m.aiLoading = false
                m.applyDraft(draft, projects: projects)
            } catch {
                guard let m, !Task.isCancelled else { return }
                m.aiLoading = false
                m.aiReason = "重新起草失败,直接改表单即可"
            }
        }
    }

    /// 采纳一份 AI 草稿(岛事件卡「采纳」按钮 / 收件箱一键采纳共用)
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

    private func finish(cleared: Bool) {
        aiTask?.cancel()
        if let mo = keyMonitor { NSEvent.removeMonitor(mo); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        model = nil
        if cleared, queue.count > 1 {
            ToastManager.shared.show("收件箱理清完毕 🎉 行动已进入工作台(⌥⌘P)", duration: 4)
        }
        queue = []
        onFinished?()
        onFinished = nil
        IslandController.shared.refresh()
    }
}

// MARK: - 模型

@MainActor
final class ClarifyModel: ObservableObject {
    let item: Item
    @Published var projects: [Project]
    let progress: String?
    let shownAt = Date()

    @Published var isActionable = true
    @Published var nextAction = ""
    @Published var expectedOutcome = ""
    @Published var list: GTDList = .action
    @Published var waitingFor = ""
    @Published var selectedProjectId: Int64? = nil
    @Published var important = false
    @Published var urgent = false
    @Published var remindAt: Date? = nil
    @Published var twoMinHint = false
    @Published var aiLoading = false
    @Published var aiReason: String? = nil
    @Published var aiQuestion: String? = nil   // 低置信时 AI 只问的那一个问题
    @Published var questionAnswer = ""         // 你的回答 → 交回 AI 重新起草

    enum IdeaDest { case someday, resource }
    @Published var ideaDestination: IdeaDest = .someday

    var userEdited = false
    var aiFilled = false
    private var filling = false

    init(item: Item, projects: [Project], progress: String?) {
        self.item = item
        self.projects = projects
        self.progress = progress
    }

    func applyDraft(_ d: OpenAIClient.ClarifyDraft, projects: [Project]) {
        filling = true
        isActionable = d.isActionable
        nextAction = d.nextAction
        expectedOutcome = d.expectedOutcome
        list = GTDList(rawValue: d.list) ?? (d.isActionable ? .action : .someday)
        waitingFor = d.waitingFor
        if let p = projects.first(where: { $0.path == d.projectPath }) { selectedProjectId = p.id }
        important = d.important
        urgent = d.urgent
        twoMinHint = d.twoMinutes
        if remindAt == nil, !d.remindDate.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            remindAt = f.date(from: d.remindDate)
        }
        aiReason = d.reason
        aiQuestion = d.isLowConfidence && (d.question?.isEmpty == false) ? d.question : nil
        aiFilled = true
        DispatchQueue.main.async { self.filling = false }
    }

    func noteEdit() {
        if !filling { userEdited = true }
    }

    var quadrantLabel: (String, Color) {
        switch (important, urgent) {
        case (true, true): return ("重要且紧急 → 现在就做", Theme.danger)
        case (true, false): return ("重要不紧急 → 排进计划", Theme.accent)
        case (false, true): return ("紧急不重要 → 尽快搞定", Theme.warning)
        case (false, false): return ("不重要不紧急 → 可考虑丢弃", .secondary)
        }
    }
}

// MARK: - 视图

struct ClarifyView: View {
    @ObservedObject var model: ClarifyModel
    let onConfirm: () -> Void
    let onRefine: () -> Void
    let onTwoMinDone: () -> Void
    let onDrop: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            originalText
            if let q = model.aiQuestion { questionBanner(q) }
            if model.twoMinHint { twoMinBanner }
            Divider()
            form
            footer
        }
        .padding(16)
        .panelChrome(width: 580)
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconBadge(systemName: "wand.and.stars", color: Theme.violet)
            Text("理清").font(Theme.fontTitle)
            if let p = model.progress {
                TagChip(text: p, color: .secondary)
            }
            Spacer()
            if model.aiLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("AI 起草中").font(Theme.fontCaption).foregroundStyle(.secondary)
                }
            } else if model.aiFilled {
                Label("AI 草稿,确认或改一处", systemImage: "sparkles")
                    .font(Theme.fontCaption).foregroundStyle(Theme.violet)
            }
        }
    }

    private var originalText: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.item.type == "link" ? "link" : "lightbulb.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.warning)
            Text(model.item.content ?? model.item.title)
                .font(Theme.fontBody)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            RemindChipEditor(remindAt: model.remindAt, showPlusWhenEmpty: true) { date in
                model.remindAt = date
                model.noteEdit()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    /// 低置信横幅:AI 只问一个最关键的问题,就地回答 → AI 重新起草整份草稿
    private func questionBanner(_ q: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.violet)
                Text("AI 想确认:\(q)")
                    .font(Theme.fontSub).foregroundStyle(Theme.violet)
                Spacer()
            }
            HStack(spacing: 8) {
                TextField("一句话回答…", text: $model.questionAnswer)
                    .textFieldStyle(.roundedBorder).font(Theme.fontSub)
                    .onSubmit { onRefine() }
                Button {
                    onRefine()
                } label: { Label("重新起草", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.violet)
                    .disabled(model.questionAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("也可以不回答,直接改下面的表单")
                .font(Theme.fontMicro).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.violet.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.violet.opacity(0.3), lineWidth: 1))
    }

    /// GTD 两分钟规则横幅(AI 判断 2 分钟内可解决时醒目提示)
    private var twoMinBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.circle.fill").foregroundStyle(Theme.warning)
            Text("这件事 2 分钟内就能解决——GTD 建议:别记了,现在就做!")
                .font(Theme.fontSub).foregroundStyle(Theme.warning)
            Spacer()
            Button(action: onTwoMinDone) { Label("做完了 ⌘T", systemImage: "checkmark") }
                .controlSize(.small).tint(Theme.warning).buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.warning.opacity(0.3), lineWidth: 1))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                fieldLabel("可执行?")
                Toggle("", isOn: $model.isActionable).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: model.isActionable) { _, v in
                        model.noteEdit()
                        if !v { model.list = .someday } else if model.list == .someday { model.list = .action }
                    }
                Text(model.isActionable ? "任务 = 具体行动 + 期望结果" : "想法——选择去向:")
                    .font(Theme.fontSub).foregroundStyle(.secondary)
                if !model.isActionable {
                    // 不可执行的想法:搁置孵化 or 沉淀为资源(PARA 闭环)
                    Picker("", selection: $model.ideaDestination) {
                        Label("搁置孵化", systemImage: "moon.zzz").tag(ClarifyModel.IdeaDest.someday)
                        Label("沉淀为资源", systemImage: "books.vertical").tag(ClarifyModel.IdeaDest.resource)
                    }
                    .pickerStyle(.segmented).controlSize(.small).frame(width: 210)
                }
                Spacer()
            }
            if model.isActionable {
                HStack {
                    fieldLabel("下一步")
                    TextField("具体到一个动作,如:发邮件给张三要接入文档", text: $model.nextAction)
                        .textFieldStyle(.roundedBorder).font(Theme.fontBody)
                        .onChange(of: model.nextAction) { _, _ in model.noteEdit() }
                }
                HStack {
                    fieldLabel("期望结果")
                    TextField("做完后能看到什么,如:拿到文档并确认可复用", text: $model.expectedOutcome)
                        .textFieldStyle(.roundedBorder).font(Theme.fontBody)
                        .onChange(of: model.expectedOutcome) { _, _ in model.noteEdit() }
                }
                listPicker
                if model.list == .waiting {
                    HStack {
                        fieldLabel("在等")
                        TextField("等谁 / 等什么,如:等张三回邮件", text: $model.waitingFor)
                            .textFieldStyle(.roundedBorder).font(Theme.fontBody)
                            .onChange(of: model.waitingFor) { _, _ in model.noteEdit() }
                    }
                }
            }
            HStack {
                fieldLabel("关联项目")
                Picker("", selection: $model.selectedProjectId) {
                    Text("不关联").tag(Optional<Int64>.none)
                    ForEach(model.projects, id: \.id) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .labelsHidden().frame(maxWidth: 240)
                .onChange(of: model.selectedProjectId) { _, _ in model.noteEdit() }
                Button {
                    // 应用内直接建项目,建完自动选中(不用跳出理清)
                    NewProjectController.shared.present { created in
                        model.projects = AppDatabase.shared.activeProjects()
                        if let p = created {
                            model.selectedProjectId = p.id
                            model.noteEdit()
                        }
                        ClarifyController.shared.refocus()
                    }
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 13)).foregroundStyle(Theme.teal)
                }
                .buttonStyle(.plain)
                .help("新建项目并关联")
                Spacer()
            }
            if model.isActionable {
                HStack(spacing: 8) {
                    fieldLabel("优先级")
                    priorityToggle("重要", isOn: $model.important, color: Theme.accent)
                    priorityToggle("紧急", isOn: $model.urgent, color: Theme.warning)
                    Text(model.quadrantLabel.0)
                        .font(Theme.fontCaption).foregroundStyle(model.quadrantLabel.1)
                    Spacer()
                }
            }
            if let reason = model.aiReason {
                Text(reason).font(Theme.fontCaption).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    /// 清单路由:三个卡片式选项,带适用说明
    private var listPicker: some View {
        HStack(alignment: .top, spacing: 6) {
            fieldLabel("清单")
            ForEach([GTDList.action, .waiting, .someday]) { l in
                Button {
                    model.list = l
                    model.noteEdit()
                } label: {
                    VStack(spacing: 3) {
                        Label(l.name, systemImage: l.icon)
                            .font(.system(size: 11.5, weight: model.list == l ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(model.list == l ? l.color.opacity(0.15) : Color.secondary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(model.list == l ? l.color.opacity(0.5) : .clear, lineWidth: 1))
                    .foregroundStyle(model.list == l ? l.color : .secondary)
                }
                .buttonStyle(.plain)
                .help(l.usage)
            }
            Spacer()
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(Theme.fontSub).frame(width: 60, alignment: .leading)
    }

    private func priorityToggle(_ label: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            model.noteEdit()
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: isOn.wrappedValue ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 3.5)
                .background(Capsule().fill(isOn.wrappedValue ? color.opacity(0.18) : Color.secondary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(isOn.wrappedValue ? color.opacity(0.5) : Color.clear, lineWidth: 1))
                .foregroundStyle(isOn.wrappedValue ? color : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(role: .destructive, action: onDrop) { Label("丢弃", systemImage: "trash") }
                .controlSize(.small)
            Text("⌘⌫").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
            if !model.twoMinHint {
                Button(action: onTwoMinDone) { Label("≤2 分钟,做完了", systemImage: "bolt") }
                    .controlSize(.small)
            }
            Spacer()
            Button("跳过", action: onSkip).controlSize(.small)
            Text("⌘→").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
            Button(action: onConfirm) { Label("确认 ↵", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}
