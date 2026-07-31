import SwiftUI

/// 收件箱:每条卡片只显示必要信息,主按钮「采纳」,低置信换成「回答一个问题」。
struct InboxView: View {
    @EnvironmentObject var store: PhoneStore
    var startClarify: () -> Void
    @State private var editing: Item?

    var body: some View {
        NavigationStack {
            Group {
                if store.inbox.isEmpty {
                    ContentUnavailableView("收件箱已清空",
                                           systemImage: "tray",
                                           description: Text("Inbox Zero ✓ 底部 ＋ 随手记"))
                } else {
                    List {
                        ForEach(store.inbox, id: \.id) { item in
                            inboxCard(item)
                        }
                    }
                }
            }
            .navigationTitle("收件箱")
            .toolbar {
                if !store.inbox.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { startClarify() } label: {
                            Label("开始理清", systemImage: "wand.and.stars")
                        }
                    }
                }
            }
            .refreshable { store.reload() }
            .onAppear { store.reload() }
            .sheet(item: $editing) { item in
                ClarifyCardSheet(item: item) { store.reload() }
            }
        }
    }

    private func inboxCard(_ item: Item) -> some View {
        let draft = DraftBox.decode(item)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.type == "link" ? "link" : "lightbulb.fill")
                    .foregroundStyle(PT.warning)
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer()
                if let r = item.remindAt {
                    PTChip(text: DateMention.format(r), color: PT.warning)
                }
            }
            if let d = draft {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(PT.violet)
                    Text(DraftBox.summary(d))
                        .font(.caption)
                        .foregroundStyle(d.isLowConfidence ? PT.warning : PT.violet)
                        .lineLimit(2)
                }
            } else {
                Text("\(relative(item.createdAt))" + (item.source.map { " · 来自 \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                if let d = draft, !d.isLowConfidence {
                    Button("采纳") {
                        if let id = item.id { DraftBox.adopt(itemId: id, draft: d) }
                        PhoneToast.shared.show("✓ 已采纳草稿")
                        store.reload()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(PT.success)
                    Button("调整") { editing = item }
                        .buttonStyle(.bordered).controlSize(.small)
                } else if let d = draft, d.isLowConfidence {
                    Button("回答一个问题") { editing = item }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(PT.violet)
                } else {
                    Button("理清") { editing = item }
                        .buttonStyle(.bordered).controlSize(.small).tint(PT.violet)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button {
                // 稍后:明天上午再提醒
                if let id = item.id {
                    let tomorrow = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0,
                                                         of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)!
                    AppDatabase.shared.setRemind(id, at: tomorrow)
                    PhoneToast.shared.show("明天上午再提醒")
                    store.reload()
                }
            } label: { Label("稍后", systemImage: "clock") }
                .tint(.gray)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                guard let id = item.id else { return }
                AppDatabase.shared.dropItem(id)
                store.reload()
                PhoneToast.shared.show("已丢弃", actionTitle: "撤销") {
                    try? AppDatabase.shared.dbQueue.write { db in
                        try db.execute(sql: "UPDATE item SET status = 'inbox' WHERE id = ?", arguments: [id])
                    }
                    store.reload()
                }
            } label: { Label("丢弃", systemImage: "trash") }
        }
    }
}

func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
}

// MARK: - 连续理清队列(全屏单卡,3 条自然停顿)

struct ClarifyQueueView: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss

    @State private var queue: [Item] = []
    @State private var index = 0
    @State private var clearedCount = 0
    @State private var showPause = false

    var body: some View {
        NavigationStack {
            Group {
                if showPause {
                    pauseCard
                } else if index < queue.count {
                    ClarifyCardView(item: queue[index]) { handled in
                        if handled { clearedCount += 1 }
                        advance()
                    }
                    .id(queue[index].id)
                } else {
                    doneCard
                }
            }
            .navigationTitle(index < queue.count ? "\(index + 1) / \(queue.count)" : "理清")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("结束") { dismiss() }
                }
            }
        }
        .onAppear {
            queue = AppDatabase.shared.inboxCaptures()
            store.reload()
        }
        .onDisappear { store.reload() }
        .interactiveDismissDisabled(false)
    }

    private func advance() {
        index += 1
        store.reload()
        // 每理清 3 条给一个自然停顿,不制造"还剩 47 条"的压力
        if clearedCount > 0, clearedCount % 3 == 0, index < queue.count {
            showPause = true
        }
    }

    private var pauseCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(PT.success)
            Text("已理清 \(clearedCount) 条").font(.title3.weight(.semibold))
            Text("继续,或先去做点别的——已确认的都保存好了")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("继续理清") { showPause = false }
                    .buttonStyle(.borderedProminent)
                Button("先结束") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private var doneCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(PT.violet)
            Text("收件箱清空了 🎉").font(.title3.weight(.semibold))
            Text("行动已就位,回到「今天」只看下一步")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - 澄清卡(单条,采纳优先,渐进展开)

struct ClarifyCardSheet: View {
    let item: Item
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ClarifyCardView(item: item) { _ in
                onDone()
                dismiss()
            }
            .navigationTitle("理清")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

struct ClarifyCardView: View {
    let item: Item
    /// handled = 用户做出了决定(采纳/确认/丢弃/两分钟);false = 跳过
    var onFinish: (Bool) -> Void

    @State private var draft: OpenAIClient.ClarifyDraft?
    @State private var expanded = false
    @State private var loadingAI = false
    // 调整态字段
    @State private var isActionable = true
    @State private var nextAction = ""
    @State private var expectedOutcome = ""
    @State private var list: GTDList = .action
    @State private var waitingFor = ""
    @State private var projectId: Int64? = nil
    @State private var important = false
    @State private var urgent = false
    // 低置信单问题
    @State private var answer = ""

    private var projects: [Project] { AppDatabase.shared.activeProjects() }

    var body: some View {
        Form {
            Section {
                Text(item.content ?? item.title)
                    .font(.body)
                    .lineLimit(4)
            } header: {
                Text(item.source.map { "来自 \($0) · \(relative(item.createdAt))" } ?? relative(item.createdAt))
            }

            if let d = draft, d.isLowConfidence, let q = d.question, !q.isEmpty, !expanded {
                Section("AI 想确认一个问题") {
                    Text(q).font(.subheadline).foregroundStyle(PT.violet)
                    TextField("一句话回答…", text: $answer)
                        .onSubmit { refine() }
                    Button {
                        refine()
                    } label: {
                        if loadingAI { ProgressView() } else { Label("重新起草", systemImage: "sparkles") }
                    }
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty || loadingAI)
                }
            } else if let d = draft, !expanded {
                Section("AI 草稿") {
                    Label(DraftBox.summary(d), systemImage: "sparkles")
                        .font(.subheadline).foregroundStyle(PT.violet)
                    if !d.reason.isEmpty {
                        Text(d.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if expanded { adjustForm }

            Section {
                if let d = draft, !d.isLowConfidence, !expanded {
                    Button {
                        if let id = item.id { DraftBox.adopt(itemId: id, draft: d) }
                        onFinish(true)
                    } label: {
                        Label("采纳草稿", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(PT.success)
                    .listRowBackground(Color.clear)
                }
                if expanded {
                    Button {
                        confirmManual()
                    } label: {
                        Label("确认", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                } else {
                    Button("调整…") {
                        seedFormFromDraft()
                        expanded = true
                    }
                }
                Button {
                    if let id = item.id {
                        PhoneTwoMin.shared.start(itemId: id, title: item.title)
                    }
                    onFinish(true)
                } label: {
                    Label("两分钟做完(马上做)", systemImage: "bolt.fill")
                }
                .tint(PT.warning)
                Button("跳过这条") { onFinish(false) }
                    .tint(.secondary)
                Button("丢弃", role: .destructive) {
                    if let id = item.id { AppDatabase.shared.dropItem(id) }
                    onFinish(true)
                }
            }
        }
        .onAppear {
            draft = DraftBox.decode(item)
            if draft == nil { fetchDraft() }
        }
    }

    // MARK: 调整态(渐进展开)

    @ViewBuilder
    private var adjustForm: some View {
        Section("这是可行动的吗?") {
            Toggle("可执行", isOn: $isActionable)
        }
        if isActionable {
            Section("下一步") {
                TextField("以动词开头,如:发邮件给张三", text: $nextAction)
                TextField("期望结果(可选)", text: $expectedOutcome)
            }
            Section("清单") {
                Picker("清单", selection: $list) {
                    ForEach(GTDList.allCases) { l in
                        Label(l.name, systemImage: l.icon).tag(l)
                    }
                }
                .pickerStyle(.segmented)
                if list == .waiting {
                    TextField("在等谁 / 等什么", text: $waitingFor)
                }
            }
            Section("更多") {
                Picker("项目", selection: $projectId) {
                    Text("不关联").tag(Optional<Int64>.none)
                    ForEach(projects, id: \.id) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                Toggle("重要", isOn: $important)
                Toggle("紧急", isOn: $urgent)
            }
        } else {
            Section("去向") {
                Text("将作为想法进入搁置清单,回顾时再决定")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func seedFormFromDraft() {
        guard let d = draft else { return }
        isActionable = d.isActionable
        nextAction = d.nextAction
        expectedOutcome = d.expectedOutcome
        list = GTDList(rawValue: d.list) ?? .action
        waitingFor = d.waitingFor
        important = d.important
        urgent = d.urgent
        projectId = projects.first { $0.path == d.projectPath }?.id
    }

    private func confirmManual() {
        guard let id = item.id else { return }
        AppDatabase.shared.applyClarify(
            itemId: id, isActionable: isActionable,
            nextAction: isActionable && !nextAction.isEmpty ? nextAction : nil,
            projectId: projectId,
            importance: important ? 1 : 0, urgency: urgent ? 1 : 0,
            list: isActionable ? list.rawValue : "someday",
            expectedOutcome: expectedOutcome.isEmpty ? nil : expectedOutcome,
            waitingFor: list == .waiting && !waitingFor.isEmpty ? waitingFor : nil,
            remindAt: nil)
        Telemetry.record(event: "clarify", itemId: id,
                         chosenPath: isActionable ? list.rawValue : "someday")
        onFinish(true)
    }

    private func refine() {
        guard let id = item.id else { return }
        let a = answer.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        let combined = (item.content ?? item.title) + "\n(补充说明:\(a))"
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET content = ?, updatedAt = ? WHERE id = ?",
                           arguments: [combined, Date(), id])
        }
        Telemetry.record(event: "clarify_refine", itemId: id)
        loadingAI = true
        fetchDraft(text: combined)
    }

    private func fetchDraft(text: String? = nil) {
        guard let client = OpenAIClient(config: EnvConfig.load()) else { return }
        loadingAI = true
        Task {
            let projects = AppDatabase.shared.activeProjects()
            let d = try? await client.clarify(
                text: text ?? (item.content ?? item.title),
                projectPaths: projects.map(\.path),
                activeProjectPath: PhoneFocus.shared.activeProjectPath)
            await MainActor.run {
                loadingAI = false
                if let d {
                    draft = d
                    answer = ""
                    if let json = try? JSONEncoder().encode(d),
                       let str = String(data: json, encoding: .utf8), let id = item.id {
                        try? AppDatabase.shared.dbQueue.write { db in
                            try db.execute(sql: "UPDATE item SET summary = ? WHERE id = ?", arguments: [str, id])
                        }
                    }
                }
            }
        }
    }
}
