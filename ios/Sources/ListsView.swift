import SwiftUI

/// 清单:一页分段切换 Action / Waiting / Someday / Done,不拆四个 Tab。
struct ListsView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var segment = 0

    var body: some View {
        NavigationStack {
            List {
                Picker("清单", selection: $segment) {
                    Text("行动").tag(0)
                    Text("等待").tag(1)
                    Text("搁置").tag(2)
                    Text("完成").tag(3)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch segment {
                case 0: actionSection
                case 1: waitingSection
                case 2: somedaySection
                default: doneSection
                }
            }
            .navigationTitle("清单")
            .refreshable { store.reload() }
            .onAppear { store.reload() }
        }
    }

    // MARK: 行动(四象限排序 + 顺序解锁)

    @ViewBuilder
    private var actionSection: some View {
        if store.nextActions.isEmpty {
            emptyRow("行动清单是空的", GTDList.action.usage)
        } else {
            ForEach(store.nextActions, id: \.id) { item in
                HStack(spacing: 10) {
                    quadrantBar(item)
                    Button {
                        store.markDone(item)
                    } label: { Image(systemName: "circle").foregroundStyle(PT.accent) }
                        .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.nextAction ?? item.title).font(.subheadline).lineLimit(2)
                        HStack(spacing: 6) {
                            if let name = store.nameOf(item) {
                                Text(name).font(.caption2).foregroundStyle(projectTint(name))
                            }
                            if let o = item.expectedOutcome, !o.isEmpty {
                                Text("→ \(o)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let r = item.remindAt {
                            Text(DateMention.format(r))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(r < Date() ? PT.danger : PT.warning)
                        }
                        if let s = item.seq {
                            Text("第 \(s) 步").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { move(item, "waiting") } label: { Label("等待", systemImage: "hourglass") }
                        .tint(PT.teal)
                    Button { move(item, "someday") } label: { Label("搁置", systemImage: "moon.zzz") }
                        .tint(.gray)
                }
            }
        }
    }

    // MARK: 等待(等待对象 + 天数 + 催办/收到)

    @ViewBuilder
    private var waitingSection: some View {
        if store.waiting.isEmpty {
            emptyRow("没有在等的事", GTDList.waiting.usage)
        } else {
            ForEach(store.waiting, id: \.id) { item in
                let days = Calendar.current.dateComponents([.day], from: item.updatedAt, to: Date()).day ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.nextAction ?? item.title).font(.subheadline).lineLimit(2)
                    HStack(spacing: 6) {
                        if let w = item.waitingFor, !w.isEmpty {
                            PTChip(text: "在等:\(w)", color: PT.teal)
                        }
                        if days >= 1 {
                            PTChip(text: "已等 \(days) 天", color: days >= 3 ? PT.danger : .secondary)
                        }
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        Button("催办") {
                            guard let id = item.id else { return }
                            try? AppDatabase.shared.dbQueue.write { db in
                                try db.execute(sql: "UPDATE item SET updatedAt = ? WHERE id = ?",
                                               arguments: [Date(), id])
                            }
                            Telemetry.record(event: "waiting_followup", itemId: id)
                            PhoneToast.shared.show("已记录催办,等待天数重新计")
                            store.reload()
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(PT.teal)
                        Button("收到结果 ✓") {
                            store.markDone(item)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(PT.success)
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: 搁置(激活或继续搁着)

    @ViewBuilder
    private var somedaySection: some View {
        if store.someday.isEmpty {
            emptyRow("搁置清单是空的", GTDList.someday.usage)
        } else {
            ForEach(store.someday, id: \.id) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.nextAction ?? item.title).font(.subheadline).lineLimit(2)
                        Text("搁置于 \(relative(item.updatedAt))").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("激活") { move(item, "action") }
                        .buttonStyle(.bordered).controlSize(.small).tint(PT.accent)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        if let id = item.id { AppDatabase.shared.dropItem(id) }
                        store.reload()
                    } label: { Label("放下", systemImage: "trash") }
                }
            }
        }
    }

    // MARK: 完成(近 7 天,可撤销)

    @ViewBuilder
    private var doneSection: some View {
        if store.doneRecent.isEmpty {
            emptyRow("最近还没有完成记录", "在行动清单勾掉第一件事吧")
        } else {
            ForEach(store.doneRecent, id: \.id) { item in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PT.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.nextAction ?? item.title)
                            .font(.subheadline).strikethrough().foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let t = item.completedAt {
                            Text(relative(t)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if let name = store.nameOf(item) {
                        Text(name).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        guard let id = item.id else { return }
                        try? AppDatabase.shared.dbQueue.write { db in
                            try db.execute(sql: "UPDATE item SET status = 'clarified', completedAt = NULL WHERE id = ?",
                                           arguments: [id])
                        }
                        store.reload()
                    } label: { Label("重新打开", systemImage: "arrow.uturn.backward") }
                        .tint(PT.accent)
                }
            }
        }
    }

    // MARK: 小件

    private func quadrantBar(_ item: Item) -> some View {
        let imp = (item.importance ?? 0) >= 1
        let urg = (item.urgency ?? 0) >= 1
        let color: Color = imp && urg ? PT.danger : (imp ? PT.accent : (urg ? PT.warning : Color.secondary.opacity(0.25)))
        return RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 28)
    }

    private func emptyRow(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(sub).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func move(_ item: Item, _ list: String) {
        guard let id = item.id else { return }
        AppDatabase.shared.moveItem(id, toList: list)
        store.reload()
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Base URL(OpenAI 兼容)", text: $baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                    TextField("模型名(区分大小写)", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("AI(可选)")
                } footer: {
                    Text("三项留空 = 纯本地模式。密钥仅保存在本机,理清草稿会把捕获文本发往你填写的接口;原始文件内容不发送。")
                }
                Section {
                    LabeledContent("数据位置", value: "本机沙盒 ~/.tidy")
                    LabeledContent("跨设备同步", value: "规划中(CloudKit)")
                    LabeledContent("版本", value: "0.1.0")
                } header: {
                    Text("关于")
                } footer: {
                    Text("Tidy for iPhone:随手收进来,随时理清,只看下一步。Mac 端负责 PARA 文件目录;两端各自离线可用。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveEnv()
                        dismiss()
                    }
                }
            }
            .onAppear {
                let env = EnvConfig.load()
                baseURL = env.baseURL ?? ""
                apiKey = env.apiKey ?? ""
                model = env.model ?? ""
            }
        }
    }

    private func saveEnv() {
        let content = """
        OPENAI_BASE_URL=\(baseURL)
        OPENAI_API_KEY=\(apiKey)
        OPENAI_MODEL=\(model)
        OPENAI_MODEL_HEAVY=
        """
        try? FileManager.default.createDirectory(at: EnvConfig.tidyDir, withIntermediateDirectories: true)
        try? content.write(to: EnvConfig.envFile, atomically: true, encoding: .utf8)
        PhoneToast.shared.show(baseURL.isEmpty ? "已保存:纯本地模式" : "已保存 AI 配置")
    }
}
