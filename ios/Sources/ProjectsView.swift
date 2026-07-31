import SwiftUI

/// 项目:为什么 → 现在做什么 → 后续链条。
/// PARA 目录真相在 Mac;手机端管理项目元数据与行动链。
struct ProjectsView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var segment = 0
    @State private var search = ""
    @State private var showNew = false
    @State private var newName = ""
    @State private var newOutcome = ""

    private var shown: [Project] {
        let base = segment == 0 ? store.projects : store.pausedProjects
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter {
            FuzzyMatcher.score(query: q, key: SearchKey($0.name)) > 0
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("状态", selection: $segment) {
                    Text("进行中 \(store.projects.count)").tag(0)
                    Text("已暂停 \(store.pausedProjects.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                ForEach(shown, id: \.id) { p in
                    NavigationLink(value: p.id ?? 0) {
                        projectRow(p)
                    }
                }
                if shown.isEmpty {
                    Text(segment == 0 ? "还没有进行中的项目" : "没有暂停的项目")
                        .font(.subheadline).foregroundStyle(.tertiary)
                }
            }
            .searchable(text: $search, prompt: "项目名(拼音首字母可)")
            .navigationTitle("项目")
            .navigationDestination(for: Int64.self) { pid in
                ProjectDetailView(projectId: pid)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { store.reload() }
            .onAppear { store.reload() }
            .alert("新建项目", isPresented: $showNew) {
                TextField("项目名称", text: $newName)
                TextField("期望结果(可选)", text: $newOutcome)
                Button("创建") { createProject() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("PARA 目录由 Mac 端创建;手机端先建立项目元数据")
            }
        }
    }

    private func projectRow(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(projectTint(p.name)).frame(width: 8, height: 8)
                Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if let due = p.dueDate {
                    let days = Calendar.current.dateComponents([.day], from: Date(), to: due).day ?? 0
                    PTChip(text: days >= 0 ? "剩 \(days) 天" : "逾期 \(-days) 天",
                           color: days < 3 ? PT.danger : .secondary)
                }
            }
            if let note = p.lastProgressNote, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let t = p.lastWorkedAt {
                Text("上次推进 \(relative(t))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func createProject() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var p = Project(id: nil, name: name, path: "1-Projects/\(name)", status: "active",
                        dueDate: nil, lastWorkedAt: nil, lastProgressNote: nil,
                        purpose: nil, outcome: newOutcome.isEmpty ? nil : newOutcome,
                        createdAt: Date(), completedAt: nil)
        try? AppDatabase.shared.dbQueue.write { db in try p.insert(db) }
        Telemetry.record(event: "project_created", chosenPath: p.path)
        newName = ""
        newOutcome = ""
        store.reload()
        PhoneToast.shared.show("✓ 项目已创建(目录待 Mac 端同步创建)")
    }
}

// MARK: - 项目详情

struct ProjectDetailView: View {
    @EnvironmentObject var store: PhoneStore
    let projectId: Int64

    @State private var chain: [Item] = []
    @State private var doneSteps = 0
    @State private var captures: [Item] = []
    @State private var showProgress = false
    @State private var progressText = ""
    @State private var showComplete = false

    private var project: Project? { AppDatabase.shared.project(byId: projectId) }

    var body: some View {
        List {
            if let p = project {
                if let purpose = p.purpose, !purpose.isEmpty {
                    Section("目的") {
                        Text(purpose).font(.subheadline)
                        if let o = p.outcome, !o.isEmpty {
                            Label(o, systemImage: "flag.checkered")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("当前下一步") {
                    if let first = chain.first {
                        HStack {
                            Button {
                                store.markDone(first)
                                load()
                            } label: {
                                Image(systemName: "circle").foregroundStyle(PT.accent)
                            }
                            .buttonStyle(.plain)
                            Text(first.nextAction ?? first.title).font(.subheadline.weight(.medium))
                            Spacer()
                            if let r = first.remindAt {
                                PTChip(text: DateMention.format(r), color: r < Date() ? PT.danger : PT.warning)
                            }
                        }
                    } else {
                        Text("没有下一步——项目会停摆,定义一个吧")
                            .font(.caption).foregroundStyle(PT.warning)
                    }
                }
                if chain.count > 1 {
                    Section("后续行动链(完成前置自动解锁)") {
                        ForEach(Array(chain.dropFirst().enumerated()), id: \.element.id) { idx, step in
                            HStack(spacing: 8) {
                                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                                Text("\(idx + 2). \(step.nextAction ?? step.title)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if doneSteps > 0 {
                            Text("已完成 \(doneSteps) 步")
                                .font(.caption2).foregroundStyle(PT.success)
                        }
                    }
                }
                Section("进展") {
                    if let note = p.lastProgressNote, !note.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note).font(.subheadline)
                            if let t = p.lastWorkedAt {
                                Text(relative(t)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Button {
                        showProgress = true
                    } label: { Label("添加进展", systemImage: "square.and.pencil") }
                }
                if !captures.isEmpty {
                    Section("待消化(\(captures.count))") {
                        ForEach(captures, id: \.id) { c in
                            Label(c.title, systemImage: c.type == "link" ? "link" : "lightbulb")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Section {
                    if p.status == "active" {
                        Button("暂停项目") { setStatus("paused") }
                        Button("完成项目", role: .destructive) { showComplete = true }
                    } else {
                        Button("恢复进行") { setStatus("active") }
                    }
                } footer: {
                    Text("PARA 目录归档(移入 4-Archive)由 Mac 端执行")
                }
            }
        }
        .navigationTitle(project?.name ?? "项目")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .alert("这次推进到哪了?", isPresented: $showProgress) {
            TextField("一句话进展", text: $progressText)
            Button("记录") {
                guard !progressText.isEmpty else { return }
                try? AppDatabase.shared.dbQueue.write { db in
                    try db.execute(sql: "UPDATE project SET lastProgressNote = ?, lastWorkedAt = ? WHERE id = ?",
                                   arguments: [progressText, Date(), projectId])
                }
                MemoryStore.shared.recordEpisodic("\(dateStr()) 项目「\(project?.name ?? "")」进展:\(progressText)",
                                                  scope: "project:\(projectId)")
                progressText = ""
                store.reload()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("完成项目?", isPresented: $showComplete) {
            Button("标记完成(目录归档由 Mac 执行)") {
                try? AppDatabase.shared.dbQueue.write { db in
                    try db.execute(sql: "UPDATE project SET status = 'done', completedAt = ? WHERE id = ?",
                                   arguments: [Date(), projectId])
                }
                Telemetry.record(event: "project_done_phone", itemId: projectId)
                store.reload()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func load() {
        chain = AppDatabase.shared.nextActions(projectId: projectId, limit: 8)
        doneSteps = AppDatabase.shared.doneStepCounts()[projectId] ?? 0
        captures = AppDatabase.shared.unprocessedCaptures(projectId: projectId)
    }

    private func setStatus(_ s: String) {
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET status = ? WHERE id = ?", arguments: [s, projectId])
        }
        store.reload()
    }
}
