import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 事件卡片

/// 岛上的一张事件卡:图标徽章 + 标题/副题 + 药丸按钮 + 底部倒计时进度条
struct IslandEvent: Identifiable {
    struct Action: Identifiable {
        let id = UUID()
        var label: String
        var prominent = false
        var handler: () -> Void
    }

    let id = UUID()
    var icon: String? = "checkmark.circle.fill"   // nil = 标题自带 emoji,不加徽章
    var color: Color = Theme.success
    var title: String
    var subtitle: String? = nil
    var actions: [Action] = []
    var duration: TimeInterval = 8
    var kind = "generic"      // 同类事件合并用
}

// MARK: - 控制器

/// Tidy Island:唯一的常驻交互入口(菜单栏图标已移除)。
/// 刘海机型:纯黑、与刘海融为一体,内容分布在左右翼;无刘海:覆盖菜单栏中央。
/// 状态机:静默(状态灯) ⇄ 预览(hover) ⇄ 事件卡(自动展开) ⇄ 归档靶(拖拽,最高优先)。
/// 一切展开都从中间向两侧生长(frame 居中锚定 + 对称动画)。
@MainActor
final class IslandController {
    static let shared = IslandController()

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<IslandView>?
    let model = IslandModel()
    private var hoverTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var lastSize: NSSize = .zero
    private var eventQueue: [IslandEvent] = []

    var onDrop: (([URL]) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: 生命周期

    func show() {
        if panel == nil { build() }
        model.refreshCounts()
        panel?.orderFrontRegardless()
        relayout(animate: false)
        startRefreshTimer()
    }

    private func hideNow() {
        panel?.orderOut(nil)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 唯一入口不允许永久消失:隐藏 1 小时后自动回归(热键始终可用)
    func hideTemporarily() {
        hideNow()
        Telemetry.record(event: "island_hide_1h")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { [weak self] in
            self?.show()
        }
    }

    func toggle() { isVisible ? hideTemporarily() : show() }

    func setFocusText(_ text: String?) {
        guard model.focusText != text else { return }
        model.focusText = text
        if model.mode == .collapsed { relayout() }
    }

    func refresh() {
        model.refreshCounts()
        if model.mode == .collapsed { relayout() }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in IslandController.shared.refresh() }
        }
    }

    // MARK: 事件卡队列

    func present(event: IslandEvent) {
        guard isVisible else { return }
        if model.event != nil || model.mode == .drop {
            // 同类合并:队列里已有同 kind 的直接替换,最多积压 3 张
            eventQueue.removeAll { $0.kind == event.kind && event.kind != "generic" }
            if eventQueue.count < 3 { eventQueue.append(event) }
            return
        }
        showEvent(event)
    }

    private func showEvent(_ e: IslandEvent) {
        model.event = e
        model.eventProgress = 1
        setMode(.event)
        Telemetry.record(event: "island_event", chosenPath: e.kind)
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            var remaining = e.duration
            while remaining > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                // hover 时暂停消失倒计时:正要点按钮时卡片跑掉是最恶劣的体验
                if !self.model.eventHovering {
                    remaining -= 0.1
                    self.model.eventProgress = max(0, remaining / e.duration)
                }
            }
            if !Task.isCancelled { self?.dismissEvent() }
        }
    }

    func dismissEvent() {
        eventTask?.cancel()
        model.event = nil
        if let next = eventQueue.first {
            eventQueue.removeFirst()
            showEvent(next)
        } else {
            setMode(.collapsed)
            refresh()
        }
    }

    func runEventAction(_ action: IslandEvent.Action) {
        Telemetry.record(event: "island_action", chosenPath: action.label)
        action.handler()
        dismissEvent()
    }

    // MARK: 面板

    private func build() {
        let view = IslandView(
            model: model,
            controller: self,
            onClick: { [weak self] in
                if self?.model.event != nil { self?.dismissEvent() }
                WorkbenchController.shared.toggle()
            },
            onHoverChange: { [weak self] h in self?.hoverChanged(h) },
            onDropTargeted: { [weak self] t in self?.dropTargeted(t) },
            onDrop: { [weak self] urls in
                self?.setMode(.collapsed)
                self?.onDrop?(urls)
            })
        let h = NSHostingView(rootView: view)
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false            // 静默态与刘海融合不能有影;展开态阴影由 SwiftUI 画
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = h
        panel = p
        hosting = h
    }

    // MARK: 状态切换

    private func hoverChanged(_ hovering: Bool) {
        model.eventHovering = hovering && model.mode == .event
        hoverTask?.cancel()
        if hovering {
            guard model.mode == .collapsed else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, let self, self.model.mode == .collapsed else { return }
                self.model.preview = TodoPreviewData.build()
                self.setMode(.peek)
                Telemetry.record(event: "island_peek")
            }
        } else {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self, self.model.mode == .peek else { return }
                self.setMode(.collapsed)
            }
        }
    }

    private func dropTargeted(_ targeted: Bool) {
        hoverTask?.cancel()
        if targeted {
            setMode(.drop)
        } else {
            setMode(model.event != nil ? .event : .collapsed)
        }
    }

    private func setMode(_ mode: IslandModel.Mode) {
        guard model.mode != mode else { return }
        if mode != .peek { model.preview = nil }
        withAnimation(.spring(duration: 0.28, bounce: 0.22)) {
            model.mode = mode
        }
        relayout()
    }

    // MARK: 布局:顶部中心锚定,向两侧与下方对称生长

    private func relayout(animate: Bool = true) {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = max(size.width, Self.minCollapsedWidth)
        guard abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5 else { return }
        lastSize = size
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                           width: size.width, height: size.height)
        if animate, panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// 刘海高度(0 = 无刘海)
    static var notchInset: CGFloat { NSScreen.main?.safeAreaInsets.top ?? 0 }

    /// 刘海宽度(0 = 无刘海):内容避开这段,分布在左右翼
    static var notchWidth: CGFloat {
        guard let s = NSScreen.main, s.safeAreaInsets.top > 0 else { return 0 }
        let left = s.auxiliaryTopLeftArea?.width ?? 0
        let right = s.auxiliaryTopRightArea?.width ?? 0
        return max(0, s.frame.width - left - right)
    }

    /// 静默态最小宽度:刘海两侧各露出一段"翼"才有岛的存在感
    static var minCollapsedWidth: CGFloat {
        notchWidth > 0 ? notchWidth + 116 : 168
    }
}

// MARK: - 模型

@MainActor
final class IslandModel: ObservableObject {
    enum Mode { case collapsed, peek, event, drop }

    @Published var mode: Mode = .collapsed
    @Published var focusText: String? = nil
    @Published var overdue = 0
    @Published var inboxCount = 0
    @Published var actionCount = 0
    @Published var preview: TodoPreviewData? = nil
    @Published var event: IslandEvent? = nil
    @Published var eventProgress: Double = 1
    var eventHovering = false

    func refreshCounts() {
        let db = AppDatabase.shared
        inboxCount = db.inboxCaptures(limit: 100).count
        actionCount = db.globalNextActions(limit: 100).count
        overdue = (try? db.dbQueue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM item WHERE remindAt < ? AND status IN ('inbox','clarified')
                """, arguments: [Date()]) ?? 0
        }) ?? 0
    }

    /// 状态灯:单一最重要状态
    var status: (icon: String, color: Color, text: String) {
        if let f = focusText { return ("timer", Theme.success, f) }
        if overdue > 0 { return ("bell.badge.fill", Theme.danger, "\(overdue) 条已到点") }
        if inboxCount >= 5 { return ("tray.full.fill", Theme.warning, "收件箱 \(inboxCount)") }
        if actionCount > 0 { return ("bolt.fill", .white.opacity(0.85), "\(actionCount) 待办") }
        return ("archivebox.fill", .white.opacity(0.4), "")
    }

    var isCalm: Bool { focusText == nil && overdue == 0 && inboxCount == 0 && actionCount == 0 }
}

// MARK: - 视图

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let controller: IslandController
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void
    let onDropTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Void

    private var notchInset: CGFloat { IslandController.notchInset }
    private var notchWidth: CGFloat { IslandController.notchWidth }
    private var collapsedHeight: CGFloat { notchInset > 0 ? notchInset : 26 }

    var body: some View {
        Group {
            switch model.mode {
            case .collapsed: collapsedView
            case .peek: peekView
            case .event: eventView
            case .drop: dropView
            }
        }
        .background(islandShape.fill(.black))
        .overlay(alignment: .bottom) {
            // 展开态底部微光描边,静默态隐去(与刘海无缝)
            if model.mode != .collapsed {
                islandShape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(model.mode == .collapsed ? 0 : 0.45),
                radius: 14, y: 6)
        .contentShape(Rectangle())
        .onHover { onHoverChange($0) }
        .onTapGesture { onClick() }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { model.mode == .drop },
                                                    set: { onDropTargeted($0) })) { providers in
            collectFileURLs(from: providers) { urls in
                if !urls.isEmpty { onDrop(urls) }
            }
            return true
        }
        .contextMenu { fullMenu }
        .help("Tidy · 悬停看待办 · 点击开工作台 · 拖文件归档 · 右键菜单")
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0,
                               bottomLeadingRadius: model.mode == .collapsed ? 12 : 18,
                               bottomTrailingRadius: model.mode == .collapsed ? 12 : 18,
                               topTrailingRadius: 0, style: .continuous)
    }

    // MARK: 右键菜单(菜单栏图标已移除,岛是唯一入口)

    @ViewBuilder
    private var fullMenu: some View {
        Button("打开工作台\t⌥⌘P") { AppActions.workbench() }
        Button("快速捕获\t⌥⌘N") { AppActions.capture() }
        Button("理清收件箱(\(model.inboxCount))\t⌥⌘I") { AppActions.clarify() }
        Button("归档 Finder 选中项\t⌥⌘A") { AppActions.archiveFinder() }
        Button("撤销上次归档\t⌥⌘Z") { AppActions.undo() }
        if FocusManager.shared.isActive {
            Button("结束聚焦…") { AppActions.endFocus() }
        }
        Divider()
        Button("每周复盘…") { AppActions.review() }
        Button("统计") { AppActions.stats() }
        Button("新手指引(GTD 心法)") { AppActions.onboarding() }
        Divider()
        Menu("设置与文件") {
            Button("AI 设置(.env)…") { AppActions.openEnv() }
            Button("编辑 MEMORY.md(归档规则)") { AppActions.openMemory() }
            Button("编辑 USER.md(用户画像)") { AppActions.openUser() }
            Button("打开 PARA 目录") { AppActions.openPara() }
            Button("自检…") { AppActions.selfCheck() }
        }
        Divider()
        Button("隐藏灵动岛 1 小时") { controller.hideTemporarily() }
        Button("退出 Tidy") { AppActions.quit() }
    }

    // MARK: 静默态:刘海左右翼布局

    private var collapsedView: some View {
        let s = model.status
        return Group {
            if notchWidth > 0 {
                // 刘海机型:图标在左翼,文字在右翼,中间让给刘海——真·融合
                HStack(spacing: 0) {
                    Image(systemName: s.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(s.color)
                        .frame(width: 50)
                    Color.clear.frame(width: notchWidth)
                    Group {
                        if s.text.isEmpty {
                            Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                        } else {
                            Text(s.text)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    .frame(minWidth: 50)
                    .padding(.horizontal, 8)
                }
                .frame(height: collapsedHeight)
            } else {
                // 无刘海:覆盖菜单栏中央的紧凑条
                HStack(spacing: 6) {
                    Image(systemName: s.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(s.color)
                    if !s.text.isEmpty {
                        Text(s.text)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: collapsedHeight)
                .frame(minWidth: IslandController.minCollapsedWidth)
            }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    // MARK: 事件卡:徽章 + 标题 + 药丸按钮 + 倒计时进度条

    private var eventView: some View {
        Group {
            if let e = model.event {
                VStack(spacing: 0) {
                    HStack(spacing: 11) {
                        if let icon = e.icon {
                            ZStack {
                                Circle().fill(e.color.opacity(0.22))
                                Image(systemName: icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(e.color)
                            }
                            .frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(2)
                            if let sub = e.subtitle {
                                Text(sub)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        ForEach(e.actions) { action in
                            Button {
                                controller.runEventAction(action)
                            } label: {
                                Text(action.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Capsule().fill(action.prominent
                                        ? AnyShapeStyle(e.color.gradient)
                                        : AnyShapeStyle(Color.white.opacity(0.12))))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, notchInset > 0 ? notchInset + 8 : 10)
                    .padding(.bottom, 10)
                    // 底部倒计时细线:hover 时暂停
                    GeometryReader { geo in
                        Capsule()
                            .fill(e.color.opacity(0.55))
                            .frame(width: geo.size.width * model.eventProgress, height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 5)
                }
                .frame(width: max(400, IslandController.minCollapsedWidth))
            }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    // MARK: 预览态

    private var peekView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                let s = model.status
                Image(systemName: s.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(s.color)
                Text(s.text.isEmpty ? "全部清空,心如止水 🧘" : s.text)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("点击打开工作台").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
            if let data = model.preview, !(data.chains.isEmpty && data.loose.isEmpty) {
                Divider().overlay(Color.white.opacity(0.12))
                ForEach(Array(data.chains.enumerated()), id: \.offset) { _, chain in
                    darkChain(chain)
                }
                if !data.loose.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(data.loose, id: \.id) { it in
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
                                Text(it.nextAction ?? it.title)
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                if let r = it.remindAt {
                                    Text(DateMention.format(r)).font(.system(size: 10))
                                        .foregroundStyle(r < Date() ? Theme.danger : Theme.warning)
                                }
                            }
                        }
                    }
                }
                if data.inboxCount > 0 {
                    Text("收件箱 \(data.inboxCount) 条待理清 · ⌥⌘I")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.warning.opacity(0.9))
                }
            } else if model.preview?.inboxCount ?? 0 > 0 {
                Text("行动清单空着,收件箱有 \(model.preview!.inboxCount) 条待理清(⌥⌘I)")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
            } else {
                Text("没有待办。⌥⌘N 捕获想法,拖文件到这里归档")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, notchInset > 0 ? notchInset + 6 : 10)
        .padding(.bottom, 12)
        .frame(width: max(390, IslandController.minCollapsedWidth), alignment: .leading)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    private func darkChain(_ chain: TodoPreviewData.Chain) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(Theme.teal)
                Text(chain.projectName).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.teal)
            }
            ForEach(Array(chain.steps.prefix(3).enumerated()), id: \.element.id) { idx, step in
                HStack(spacing: 6) {
                    if idx == 0 {
                        Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
                    } else {
                        Image(systemName: chain.hasSequence ? "lock.fill" : "circle.dotted")
                            .font(.system(size: 7)).foregroundStyle(.white.opacity(0.25))
                            .padding(.leading, 8)
                    }
                    Text(step.nextAction ?? step.title)
                        .font(.system(size: idx == 0 ? 12 : 10.5, weight: idx == 0 ? .medium : .regular))
                        .foregroundStyle(idx == 0 ? .white.opacity(0.92) : .white.opacity(0.4))
                        .lineLimit(1)
                    if idx == 0, let r = step.remindAt {
                        Text(DateMention.format(r)).font(.system(size: 9.5))
                            .foregroundStyle(r < Date() ? Theme.danger : Theme.warning)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 归档靶态

    private var dropView: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("放手归档")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 30)
        .padding(.top, notchInset > 0 ? notchInset : 0)
        .frame(height: max(40, collapsedHeight + 12))
        .frame(minWidth: IslandController.minCollapsedWidth)
        .background(
            islandShape.fill(LinearGradient(colors: [Color(red: 0.3, green: 0.5, blue: 1.0),
                                                     Color(red: 0.55, green: 0.35, blue: 0.95)],
                                            startPoint: .leading, endPoint: .trailing))
        )
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func collectFileURLs(from providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

// MARK: - 预览数据

/// 按项目分组的行动链 + 独立行动
struct TodoPreviewData {
    struct Chain {
        let projectName: String
        let steps: [Item]
        let hasSequence: Bool
    }
    var chains: [Chain] = []
    var loose: [Item] = []
    var inboxCount = 0
    var doneToday = 0

    var isEmpty: Bool { chains.isEmpty && loose.isEmpty && inboxCount == 0 }

    @MainActor
    static func build() -> TodoPreviewData {
        var data = TodoPreviewData()
        let db = AppDatabase.shared
        data.inboxCount = db.inboxCaptures(limit: 100).count
        data.doneToday = db.doneTodayCount()

        let items = db.actionableOpen(limit: 100)
        let pids = db.projectIds(forItems: items.compactMap(\.id))
        let names = db.projectNames(forItems: items.compactMap(\.id))

        var grouped: [Int64: [Item]] = [:]
        for it in items {
            if let id = it.id, let pid = pids[id] {
                grouped[pid, default: []].append(it)
            } else {
                data.loose.append(it)
            }
        }
        for (_, steps) in grouped {
            let sorted = steps.sorted {
                if let a = $0.seq, let b = $1.seq { return a < b }
                if $0.seq != nil { return true }
                if $1.seq != nil { return false }
                return ($0.urgency ?? 0, $0.importance ?? 0) > ($1.urgency ?? 0, $1.importance ?? 0)
            }
            guard let first = sorted.first, let fid = first.id,
                  let name = names[fid] else { continue }
            data.chains.append(Chain(projectName: name,
                                     steps: Array(sorted.prefix(4)),
                                     hasSequence: sorted.contains { $0.seq != nil }))
        }
        data.chains.sort { ($0.steps.first?.urgency ?? 0) > ($1.steps.first?.urgency ?? 0) }
        data.chains = Array(data.chains.prefix(3))
        data.loose = Array(data.loose.prefix(3))
        return data
    }
}
