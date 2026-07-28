import AppKit
import SwiftUI

/// AI 辅助拆解(GTD 自然计划法):1 明确目的 → 2 期望结果 → 3 头脑风暴 → 4 组织计划。
/// 步骤支持增删改、上下移、按逻辑/时间排序;确认后成为带序号的行动链,
/// 完成前置步骤自动解锁后置(全局行动列表只露出链条最前一步)。
@MainActor
final class PlanController {
    static let shared = PlanController()

    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var model: PlanModel?
    private var aiTask: Task<Void, Never>?

    var aiClient: OpenAIClient?
    private var onFinished: (() -> Void)?

    func present(project: Project, seedGoal: String? = nil, onFinished: (() -> Void)? = nil) {
        close()
        self.onFinished = onFinished
        let m = PlanModel(project: project, goal: seedGoal ?? "")
        model = m

        let view = PlanView(model: m,
                            onGenerate: { [weak self] in self?.generate() },
                            onConfirm: { [weak self] in self?.confirm() },
                            onCancel: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        let width: CGFloat = 620
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
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
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - width / 2, y: f.minY + f.height * 0.85))
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

    private func generate() {
        guard let m = model, !m.goal.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let client = aiClient else {
            m.errorText = "AI 未配置(~/.tidy/.env),可手动添加步骤"
            return
        }
        m.loading = true
        m.errorText = nil
        aiTask?.cancel()
        aiTask = Task { [weak self, weak m] in
            do {
                guard let pid = m?.project.id else { return }
                let existing = AppDatabase.shared.nextActions(projectId: pid, limit: 8).compactMap(\.nextAction)
                let draft = try await client.plan(goal: m?.goal ?? "",
                                                  projectName: m?.project.name ?? "",
                                                  existingActions: existing)
                guard let self, let m, self.model === m, !Task.isCancelled else { return }
                m.apply(draft)
                Telemetry.record(event: "plan_generated", itemId: pid,
                                 suggestedPaths: draft.steps.map(\.action), usedCloud: true)
            } catch {
                guard let m, !Task.isCancelled else { return }
                m.loading = false
                m.errorText = "拆解失败:\((error as? OpenAIClient.AIError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func confirm() {
        guard let m = model, let pid = m.project.id, !m.steps.isEmpty else { return }
        let steps = m.displaySteps.map { step in
            (action: step.action, remindAt: step.date)
        }
        AppDatabase.shared.savePlan(projectId: pid, purpose: m.purpose, outcome: m.outcome, steps: steps)
        MemoryStore.shared.recordEpisodic(
            "\(Archiver.dateStr()) AI 拆解「\(m.goal.prefix(30))」→ \(steps.count) 步计划(项目:\(m.project.name))",
            scope: "project:\(pid)")
        ToastManager.shared.show("已生成 \(steps.count) 步计划,第 1 步已进入行动清单:「\(steps.first?.action.prefix(18) ?? "")」", duration: 4)
        close()
    }

    func close() {
        aiTask?.cancel()
        if let mo = keyMonitor { NSEvent.removeMonitor(mo); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        model = nil
        onFinished?()
        onFinished = nil
    }
}

// MARK: - 模型

@MainActor
final class PlanModel: ObservableObject {
    let project: Project

    @Published var goal: String
    @Published var purpose = ""
    @Published var outcome = ""
    @Published var brainstorm: [String] = []
    @Published var steps: [PlanStep] = []
    @Published var sortByTime = false      // false = 逻辑顺序,true = 时间顺序
    @Published var loading = false
    @Published var generated = false
    @Published var errorText: String? = nil

    struct PlanStep: Identifiable {
        let id = UUID()
        var action: String
        var order: Int
        var date: Date?      // timeHint 解析结果
        var timeHint: String
    }

    init(project: Project, goal: String) {
        self.project = project
        self.goal = goal
        if let p = project.purpose { purpose = p }
        if let o = project.outcome { outcome = o }
    }

    func apply(_ draft: OpenAIClient.PlanDraft) {
        loading = false
        generated = true
        purpose = draft.purpose
        outcome = draft.outcome
        brainstorm = draft.brainstorm
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        steps = draft.steps.sorted { $0.order < $1.order }.enumerated().map { i, s in
            var date = f.date(from: s.timeHint)
            if date == nil, !s.timeHint.isEmpty { date = DateMention.detect(in: s.timeHint) }
            if let d = date { date = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: d) }
            return PlanStep(action: s.action, order: i + 1, date: date, timeHint: s.timeHint)
        }
    }

    /// 当前排序模式下的步骤(时间排序:有时间的在前按时间升序,无时间的保持逻辑顺序垫后)
    var displaySteps: [PlanStep] {
        if sortByTime {
            let dated = steps.filter { $0.date != nil }.sorted { $0.date! < $1.date! }
            let rest = steps.filter { $0.date == nil }.sorted { $0.order < $1.order }
            return dated + rest
        }
        return steps.sorted { $0.order < $1.order }
    }

    func move(_ step: PlanStep, up: Bool) {
        let ordered = displaySteps
        guard let idx = ordered.firstIndex(where: { $0.id == step.id }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard ordered.indices.contains(target) else { return }
        // 交换逻辑序号并切回逻辑排序(手动调序即表达逻辑顺序)
        var a = ordered[idx], b = ordered[target]
        swap(&a.order, &b.order)
        steps = steps.map { $0.id == a.id ? a : ($0.id == b.id ? b : $0) }
        sortByTime = false
    }

    func remove(_ step: PlanStep) {
        steps.removeAll { $0.id == step.id }
    }

    func addStep() {
        steps.append(PlanStep(action: "", order: (steps.map(\.order).max() ?? 0) + 1, date: nil, timeHint: ""))
        generated = true
    }

    func setDate(_ date: Date?, for step: PlanStep) {
        if let i = steps.firstIndex(where: { $0.id == step.id }) { steps[i].date = date }
    }

    func binding(for step: PlanStep) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.steps.first { $0.id == step.id }?.action ?? "" },
            set: { [weak self] v in
                guard let self, let i = self.steps.firstIndex(where: { $0.id == step.id }) else { return }
                self.steps[i].action = v
            })
    }
}

// MARK: - 视图

struct PlanView: View {
    @ObservedObject var model: PlanModel
    let onGenerate: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var goalFocused: Bool
    @State private var editingStepId: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    goalInput
                    if let err = model.errorText {
                        Text(err).font(Theme.fontCaption).foregroundStyle(Theme.danger)
                    }
                    if model.generated {
                        purposeOutcome
                        if !model.brainstorm.isEmpty { brainstormSection }
                        stepsSection
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 420)
            Divider().padding(.horizontal, 14)
            footer
        }
        .panelChrome(width: 620)
        .onAppear { goalFocused = model.goal.isEmpty }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconBadge(systemName: "square.stack.3d.up.fill", color: Theme.violet)
            Text("AI 拆解 · \(model.project.name)").font(Theme.fontTitle)
            TagChip(text: "自然计划法", color: Theme.violet)
            Spacer()
            if model.loading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("拆解中").font(Theme.fontCaption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var goalInput: some View {
        HStack(spacing: 8) {
            TextField("要拆解的任务/目标,如:上线支付网关灰度环境", text: $model.goal)
                .textFieldStyle(.roundedBorder).font(Theme.fontBody)
                .focused($goalFocused)
                .onSubmit { onGenerate() }
            Button(action: onGenerate) {
                Label(model.generated ? "重新拆解" : "开始拆解", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(model.loading || model.goal.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var purposeOutcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            planField("1", "目的", "为什么做", text: $model.purpose, color: Theme.accent)
            planField("2", "期望结果", "做成什么样", text: $model.outcome, color: Theme.success)
        }
    }

    private func planField(_ num: String, _ title: String, _ placeholder: String,
                           text: Binding<String>, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            stepNumber(num, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.fontSub).foregroundStyle(color)
                TextField(placeholder, text: text, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.fontBody).lineLimit(1...2)
            }
        }
    }

    private var brainstormSection: some View {
        HStack(alignment: .top, spacing: 8) {
            stepNumber("3", color: Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("头脑风暴 · 要考虑的点").font(Theme.fontSub).foregroundStyle(Theme.warning)
                FlowChips(items: model.brainstorm)
            }
        }
    }

    private var stepsSection: some View {
        HStack(alignment: .top, spacing: 8) {
            stepNumber("4", color: Theme.violet)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("组织计划 · \(model.steps.count) 步").font(Theme.fontSub).foregroundStyle(Theme.violet)
                    Spacer()
                    Picker("", selection: $model.sortByTime) {
                        Text("按逻辑").tag(false)
                        Text("按时间").tag(true)
                    }
                    .pickerStyle(.segmented).controlSize(.mini).frame(width: 130)
                    Button { model.addStep() } label: { Image(systemName: "plus") }
                        .controlSize(.mini).help("添加一步")
                }
                ForEach(Array(model.displaySteps.enumerated()), id: \.element.id) { idx, step in
                    stepRow(step, index: idx)
                }
                Text("确认后成为行动链:全局行动清单只露出第 1 步,完成后自动解锁下一步")
                    .font(Theme.fontMicro).foregroundStyle(.tertiary)
            }
        }
    }

    private func stepRow(_ step: PlanModel.PlanStep, index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 16, height: 16)
                .background(Circle().fill(index == 0 ? Theme.accent : Color.secondary.opacity(0.15)))
                .foregroundStyle(index == 0 ? .white : .secondary)
            TextField("步骤内容", text: model.binding(for: step))
                .textFieldStyle(.plain).font(Theme.fontBody)
            // 时间节点:AI 生成,点击修正(日历弹层),没有则可补加
            Button {
                editingStepId = step.id
            } label: {
                if let d = step.date {
                    TagChip(text: "⏰ \(DateMention.format(d))", color: Theme.warning)
                } else {
                    TagChip(text: "＋时间", color: .secondary)
                }
            }
            .buttonStyle(.plain)
            .help("设置/修正这一步的时间节点(会成为提醒)")
            .popover(isPresented: Binding(
                get: { editingStepId == step.id },
                set: { if !$0 { editingStepId = nil } })) {
                StepDatePopover(initial: step.date ?? Date().addingTimeInterval(86400),
                                hasDate: step.date != nil,
                                onSave: { d in model.setDate(d, for: step); editingStepId = nil },
                                onClear: { model.setDate(nil, for: step); editingStepId = nil })
            }
            Button { model.move(step, up: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).font(.system(size: 10))
            Button { model.move(step, up: false) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).font(.system(size: 10))
            Button { model.remove(step) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).font(.system(size: 9))
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(index == 0 ? 0.07 : 0.03)))
    }

    private func stepNumber(_ n: String, color: Color) -> some View {
        Text(n)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 20, height: 20)
            .background(Circle().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var footer: some View {
        HStack {
            Text("esc 取消").font(Theme.fontCaption).foregroundStyle(.tertiary)
            Spacer()
            Button("取消", action: onCancel).controlSize(.small)
            Button(action: onConfirm) {
                Label("确认计划,进入行动清单", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(model.steps.isEmpty || model.steps.allSatisfy { $0.action.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// 步骤时间节点编辑弹层
private struct StepDatePopover: View {
    let initial: Date
    let hasDate: Bool
    let onSave: (Date) -> Void
    let onClear: () -> Void
    @State private var draft = Date()

    var body: some View {
        VStack(spacing: 8) {
            DatePicker("", selection: $draft, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(width: 240)
            HStack {
                if hasDate {
                    Button("清除时间") { onClear() }.controlSize(.small)
                }
                Spacer()
                Button("保存") { onSave(draft) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(12)
        .onAppear { draft = initial }
    }
}

/// 简单的标签流式布局
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 5) {
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 4, height: 4)
                    Text(item).font(Theme.fontSub).foregroundStyle(.secondary)
                }
            }
        }
    }
}
