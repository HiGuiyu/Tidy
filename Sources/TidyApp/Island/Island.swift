import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tidy Island(M1):顶部居中的灵动岛。
/// 刘海机型贴刘海(黑底融合);无刘海屏覆盖菜单栏中央。永不抢焦点、全屏应用下依然可见。
/// 三态:静默(状态灯) ⇄ 预览(hover 展开待办逻辑) ⇄ 归档靶(文件拖入)。
/// 点击 = 开关工作台;右键 = 菜单。M2 将接入事件卡片系统。
@MainActor
final class IslandController {
    static let shared = IslandController()

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<IslandView>?
    private let model = IslandModel()
    private var hoverTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var lastSize: NSSize = .zero

    var onDrop: (([URL]) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 生命周期

    func show() {
        if panel == nil { build() }
        model.refreshCounts()
        panel?.orderFrontRegardless()
        relayout(animate: false)
        UserDefaults.standard.set(true, forKey: "islandVisible")
        startRefreshTimer()
    }

    func hide() {
        panel?.orderOut(nil)
        refreshTimer?.invalidate()
        refreshTimer = nil
        UserDefaults.standard.set(false, forKey: "islandVisible")
    }

    func toggle() { isVisible ? hide() : show() }

    /// 聚焦倒计时上岛(FocusManager 每秒驱动)
    func setFocusText(_ text: String?) {
        guard model.focusText != text else { return }
        model.focusText = text
        if model.mode == .collapsed { relayout() }
    }

    /// 外部数据变化后刷新状态灯(归档/理清/完成后调用,或定时器)
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

    // MARK: - 面板

    private func build() {
        let view = IslandView(
            model: model,
            onClick: { WorkbenchController.shared.toggle() },
            onHoverChange: { [weak self] h in self?.hoverChanged(h) },
            onDropTargeted: { [weak self] t in self?.dropTargeted(t) },
            onDrop: { [weak self] urls in
                self?.setMode(.collapsed)
                self?.onDrop?(urls)
            },
            onHide: { [weak self] in
                self?.hide()
                ToastManager.shared.show("灵动岛已隐藏,菜单栏「显示/隐藏灵动岛」可恢复", duration: 3)
            })
        let h = NSHostingView(rootView: view)
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .statusBar          // 盖过菜单栏
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = h
        panel = p
        hosting = h
    }

    // MARK: - 状态切换

    private func hoverChanged(_ hovering: Bool) {
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
        setMode(targeted ? .drop : .collapsed)
    }

    private func setMode(_ mode: IslandModel.Mode) {
        guard model.mode != mode else { return }
        if mode != .peek { model.preview = nil }
        withAnimation(.spring(duration: 0.25, bounce: 0.25)) {
            model.mode = mode
        }
        relayout()
    }

    // MARK: - 布局:顶部居中锚定,向下生长

    private func relayout(animate: Bool = true) {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = max(size.width, 120)
        guard abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5 else { return }
        lastSize = size
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                           width: size.width, height: size.height)
        if animate, panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// 刘海高度(0 = 无刘海)
    static var notchInset: CGFloat { NSScreen.main?.safeAreaInsets.top ?? 0 }
}

// MARK: - 模型

@MainActor
final class IslandModel: ObservableObject {
    enum Mode { case collapsed, peek, drop }

    @Published var mode: Mode = .collapsed
    @Published var focusText: String? = nil
    @Published var overdue = 0
    @Published var inboxCount = 0
    @Published var actionCount = 0
    @Published var preview: TodoPreviewData? = nil

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

    /// 状态灯:单一最重要状态,按优先级取一
    var status: (icon: String, color: Color, text: String) {
        if let f = focusText {
            return ("timer", Theme.success, f)
        }
        if overdue > 0 {
            return ("bell.badge.fill", Theme.danger, "\(overdue) 条已到点")
        }
        if inboxCount >= 5 {
            return ("tray.full.fill", Theme.warning, "收件箱 \(inboxCount)")
        }
        if actionCount > 0 {
            return ("bolt.fill", .white.opacity(0.9), "\(actionCount) 待办")
        }
        return ("archivebox.fill", .white.opacity(0.45), "")
    }

    var isCalm: Bool { focusText == nil && overdue == 0 && inboxCount == 0 && actionCount == 0 }
}

// MARK: - 视图

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void
    let onDropTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Void
    let onHide: () -> Void

    /// 刘海机型胶囊更高,与刘海融为一体
    private var collapsedHeight: CGFloat { max(28, IslandController.notchInset) }

    var body: some View {
        Group {
            switch model.mode {
            case .collapsed: collapsedView
            case .peek: peekView
            case .drop: dropView
            }
        }
        .background(islandShape.fill(Color.black.opacity(model.isCalm && model.mode == .collapsed ? 0.62 : 0.86)))
        .overlay(islandShape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
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
        .contextMenu {
            Button("打开工作台(⌥⌘P)") { onClick() }
            Button("隐藏灵动岛") { onHide() }
        }
        .help("Tidy · 悬停看待办 · 点击开工作台 · 拖文件归档")
    }

    /// 贴顶造型:上方直角(与屏幕顶/刘海齐平),下方圆角
    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14,
                               bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous)
    }

    // MARK: 静默态:状态灯

    private var collapsedView: some View {
        let s = model.status
        return HStack(spacing: 6) {
            Image(systemName: s.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(s.color)
            if !s.text.isEmpty {
                Text(s.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: collapsedHeight)
        .frame(minWidth: 120)
    }

    // MARK: 预览态:待办逻辑下垂展开

    private var peekView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                let s = model.status
                Image(systemName: s.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(s.color)
                Text(s.text.isEmpty ? "全部清空,心如止水 🧘" : s.text)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("点击打开工作台").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            if let data = model.preview, !(data.chains.isEmpty && data.loose.isEmpty) {
                Divider().overlay(Color.white.opacity(0.15))
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
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, IslandController.notchInset > 0 ? IslandController.notchInset : 10)
        .padding(.bottom, 12)
        .frame(width: 380, alignment: .leading)
    }

    /// 深色版行动链:▶ 当前步白亮,后置步 🔒 灰显
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
        .padding(.horizontal, 26)
        .frame(height: max(36, collapsedHeight + 6))
        .background(
            islandShape.fill(LinearGradient(colors: [Color(red: 0.3, green: 0.5, blue: 1.0),
                                                     Color(red: 0.55, green: 0.35, blue: 0.95)],
                                            startPoint: .leading, endPoint: .trailing))
        )
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

// MARK: - 预览数据(自旧悬浮圆点迁移)

/// 按项目分组的行动链 + 独立行动
struct TodoPreviewData {
    struct Chain {
        let projectName: String
        let steps: [Item]      // 已按 seq/优先级排序,第 0 条 = 当前可做,其余为锁定的后置步
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
