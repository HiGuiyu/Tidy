import SwiftUI

/// Today:可行动的简报,不是所有数据的仪表盘。
/// 首屏最多:正在进行 / 首要下一步 / 接下来三条 / 一个系统提示。
struct TodayView: View {
    @EnvironmentObject var store: PhoneStore
    @StateObject private var focus = PhoneFocus.shared
    @StateObject private var twoMin = PhoneTwoMin.shared
    @Binding var showCapture: Bool
    var startClarify: () -> Void

    @State private var showFocusPicker: Item?
    @State private var showEndNote = false
    @State private var endNote = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if twoMin.isActive { twoMinSection }
                if focus.isActive { focusSection }
                nextSection
                if let hint = store.hint { hintSection(hint) }
                if store.doneToday > 0 {
                    Section {
                        Label("今天已完成 \(store.doneToday) 件", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(PT.success)
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            .navigationTitle(todayTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { store.reload() }
            .onAppear { store.reload() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("开始专注", isPresented: Binding(
                get: { showFocusPicker != nil }, set: { if !$0 { showFocusPicker = nil } })) {
                ForEach([15, 25, 50], id: \.self) { m in
                    Button("\(m) 分钟") {
                        if let item = showFocusPicker {
                            startFocus(item, minutes: m)
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(showFocusPicker.map { $0.nextAction ?? $0.title } ?? "")
            }
            .alert("这次做到哪了?", isPresented: $showEndNote) {
                TextField("一句话进展(可留空)", text: $endNote)
                Button("结束并记录") {
                    focus.end(note: endNote.isEmpty ? nil : endNote)
                    endNote = ""
                    store.reload()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var todayTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f.string(from: Date())
    }

    // MARK: 正在进行:两分钟即办

    private var twoMinSection: some View {
        Section("正在进行") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bolt.fill").foregroundStyle(PT.warning)
                        Text(twoMin.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(twoMin.isTimeUp ? "时间到" : String(format: "%d:%02d", twoMin.remaining / 60, twoMin.remaining % 60))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(PT.warning)
                    }
                    if twoMin.isTimeUp {
                        HStack {
                            Button("搞定 ✓") {
                                twoMin.finish(done: true)
                                store.reload()
                            }
                            .buttonStyle(.borderedProminent).tint(PT.warning)
                            Button("放回收件箱") {
                                twoMin.finish(done: false)
                                store.reload()
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Button("提前搞定 ✓") {
                            twoMin.finish(done: true)
                            store.reload()
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(PT.warning)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: 正在进行:专注

    private var focusSection: some View {
        Section("正在进行") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: focus.isPaused ? "pause.circle.fill" : "play.circle.fill")
                            .foregroundStyle(PT.success)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(focus.actionTitle ?? focus.projectName ?? "专注中")
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let p = focus.projectName, focus.actionTitle != nil {
                                Text(p).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(focusTimeText)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(focus.remaining >= 0 ? PT.success : PT.warning)
                    }
                    HStack {
                        if focus.isPaused {
                            Button("继续") { focus.resume() }
                                .buttonStyle(.borderedProminent).controlSize(.small).tint(PT.success)
                        } else {
                            Button("暂停") { focus.pause() }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        if focus.remaining < 0 {
                            Button("延长 10 分钟") { focus.extend(minutes: 10) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        Spacer()
                        Button("结束") { showEndNote = true }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var focusTimeText: String {
        let r = focus.remaining
        if focus.isPaused { return "⏸ 已专注 \(fmt(focus.elapsed))" }
        return r >= 0 ? fmt(r) : "+\(fmt(-r))"
    }

    private func fmt(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    // MARK: 下一步

    private var nextSection: some View {
        Section("下一步") {
            if store.nextActions.isEmpty {
                emptyGuide
            } else {
                let first = store.nextActions[0]
                primaryActionRow(first)
                ForEach(store.nextActions.dropFirst().prefix(3), id: \.id) { item in
                    actionRow(item)
                }
                if store.nextActions.count > 4 {
                    Text("其余 \(store.nextActions.count - 4) 条在「清单」")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 首要下一步:大字号 + 开始专注
    private func primaryActionRow(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.nextAction ?? item.title)
                        .font(.headline)
                    HStack(spacing: 6) {
                        if let name = store.nameOf(item) {
                            PTChip(text: name, color: projectTint(name))
                        }
                        if let r = item.remindAt {
                            PTChip(text: DateMention.format(r), color: r < Date() ? PT.danger : PT.warning)
                        }
                        if let s = item.seq {
                            PTChip(text: "第 \(s) 步", color: PT.accent)
                        }
                    }
                }
                Spacer()
                Button {
                    store.markDone(item)
                } label: {
                    Image(systemName: "circle").font(.title2).foregroundStyle(PT.accent)
                }
                .buttonStyle(.plain)
            }
            Button {
                showFocusPicker = item
            } label: {
                Label("开始专注", systemImage: "timer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(focus.isActive)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            Button {
                moveTo(item, "waiting")
            } label: { Label("等待", systemImage: "hourglass") }
                .tint(PT.teal)
            Button {
                moveTo(item, "someday")
            } label: { Label("搁置", systemImage: "moon.zzz") }
                .tint(.gray)
        }
    }

    private func actionRow(_ item: Item) -> some View {
        HStack {
            Button {
                store.markDone(item)
            } label: {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.nextAction ?? item.title).font(.subheadline).lineLimit(1)
                if let name = store.nameOf(item) {
                    Text(name).font(.caption2).foregroundStyle(projectTint(name))
                }
            }
            Spacer()
            if let r = item.remindAt {
                Text(DateMention.format(r))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(r < Date() ? PT.danger : .secondary)
            }
        }
        .swipeActions(edge: .leading) {
            Button { moveTo(item, "waiting") } label: { Label("等待", systemImage: "hourglass") }
                .tint(PT.teal)
            Button { moveTo(item, "someday") } label: { Label("搁置", systemImage: "moon.zzz") }
                .tint(.gray)
        }
    }

    private func moveTo(_ item: Item, _ list: String) {
        guard let id = item.id else { return }
        AppDatabase.shared.moveItem(id, toList: list)
        store.reload()
    }

    private func startFocus(_ item: Item, minutes: Int) {
        let pid = item.id.flatMap { AppDatabase.shared.projectIds(forItems: [$0])[$0] }
        PhoneFocus.shared.start(actionTitle: item.nextAction ?? item.title,
                                projectId: pid, minutes: minutes)
        store.reload()
    }

    // MARK: 空状态引导(不显示"你无事可做"的消极空白)

    @ViewBuilder
    private var emptyGuide: some View {
        if !store.inbox.isEmpty {
            Button { startClarify() } label: {
                Label("先理清收件箱的 \(store.inbox.count) 条想法", systemImage: "wand.and.stars")
            }
        } else if !store.waiting.isEmpty {
            Text("行动清单已空。看看「等待」里有没有该跟进的")
                .font(.subheadline).foregroundStyle(.secondary)
        } else if !store.projects.isEmpty {
            Text("给一个项目定义下一步行动吧(项目页)")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            Label("系统已清空,可以放心休息 🧘", systemImage: "checkmark.seal")
                .foregroundStyle(PT.success)
        }
    }

    private func hintSection(_ hint: SystemHint) -> some View {
        Section {
            Button {
                switch hint.kind {
                case .inbox, .overdue: startClarify()
                case .waiting: break
                }
            } label: {
                HStack {
                    Image(systemName: hint.icon).foregroundStyle(hint.color)
                    Text(hint.text).font(.subheadline)
                    Spacer()
                    Text(hint.actionTitle).font(.caption.weight(.semibold)).foregroundStyle(hint.color)
                }
            }
        }
    }
}
