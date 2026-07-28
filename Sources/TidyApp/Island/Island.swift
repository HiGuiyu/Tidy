import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 造型:贴顶粘连

/// 岛形:上缘与屏幕边缘"粘连"——顶部两角向外张开的凹弧,下缘圆角(可动画)。
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat = 9

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x0 = rect.minX + flare
        let x1 = rect.maxX - flare
        let r = min(bottomRadius, (x1 - x0) / 2, rect.height - flare)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: x0, y: rect.minY + flare),
                       control: CGPoint(x: x0, y: rect.minY))
        p.addLine(to: CGPoint(x: x0, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: x0 + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: x1 - r, y: rect.maxY))
        p.addArc(center: CGPoint(x: x1 - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: x1, y: rect.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: x1, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 像素图标(vibeisland 式 8-bit 常驻状态标)

struct PixelGlyph: View {
    let pattern: [String]
    var color: Color
    var pixel: CGFloat = 1.8

    var body: some View {
        Canvas { ctx, _ in
            for (y, row) in pattern.enumerated() {
                for (x, ch) in row.enumerated() where ch == "X" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                         width: pixel - 0.3, height: pixel - 0.3)),
                             with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(pattern.map(\.count).max() ?? 0) * pixel,
               height: CGFloat(pattern.count) * pixel)
    }
}

/// 工作中的像素标:持续呼吸闪烁——"我正在做事"的心跳
struct WorkingGlyph: View {
    let pattern: [String]
    var color: Color
    var pixel: CGFloat = 1.9

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { tl in
            let on = Int(tl.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            PixelGlyph(pattern: pattern, color: color.opacity(on ? 1 : 0.4), pixel: pixel)
        }
    }
}

enum Pixel {
    static let bolt = [
        "...XX.",
        "..XX..",
        ".XXXX.",
        "...XX.",
        "..XX..",
        ".XX...",
    ]
    static let bell = [
        "..XX..",
        ".XXXX.",
        ".XXXX.",
        ".XXXX.",
        "XXXXXX",
        "..XX..",
    ]
    static let tray = [
        "..XX..",
        "..XX..",
        ".XXXX.",
        "X....X",
        "X....X",
        "XXXXXX",
    ]
    static let play = [
        "X.....",
        "XX....",
        "XXX...",
        "XXXX..",
        "XXX...",
        "XX....",
        "X.....",
    ]
    static let calm = [
        "......",
        "..XX..",
        "..XX..",
        "......",
    ]
}

// MARK: - 事件卡片

struct IslandEvent: Identifiable {
    struct Action: Identifiable {
        let id = UUID()
        var label: String
        var prominent = false
        var handler: () -> Void
    }

    let id = UUID()
    var icon: String? = "checkmark.circle.fill"
    var color: Color = Theme.success
    var title: String
    var subtitle: String? = nil
    var actions: [Action] = []
    var duration: TimeInterval = 8
    var kind = "generic"
}

// MARK: - 点击穿透宿主

/// 窗口是固定大小的透明画布,岛体只占顶部中央一块——
/// 岛体之外的区域 hitTest 放行,不遮挡菜单栏/桌面点击。
final class IslandHostingView: NSHostingView<IslandView> {
    var coreSize: () -> CGSize = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let s = coreSize()
        let rect = NSRect(x: (bounds.width - s.width) / 2,
                          y: bounds.height - s.height,
                          width: s.width, height: s.height)
        return rect.insetBy(dx: -2, dy: -2).contains(p) ? super.hitTest(point) : nil
    }

    required init(rootView: IslandView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("unsupported") }
}

// MARK: - 控制器

/// Tidy Island:唯一的常驻交互入口。
/// 窗口固定不动(顶部居中的透明画布),一切展开/收起都是同一块黑色岛体
/// 在 SwiftUI 里连续变形——绝无"关掉旧窗口开新窗口"的割裂感,也没有窗口层阴影。
@MainActor
final class IslandController {
    static let shared = IslandController()

    private var panel: KeyablePanel?
    private var hosting: IslandHostingView?
    let model = IslandModel()
    private var hoverTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var eventQueue: [IslandEvent] = []
    private(set) var coreSize: CGSize = .zero

    var onDrop: (([URL]) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: 尺寸体系

    static var screen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }
    static var notchInset: CGFloat { screen?.safeAreaInsets.top ?? 0 }
    static var notchWidth: CGFloat {
        guard let s = screen, s.safeAreaInsets.top > 0 else { return 0 }
        let left = s.auxiliaryTopLeftArea?.width ?? 0
        let right = s.auxiliaryTopRightArea?.width ?? 0
        return max(0, s.frame.width - left - right)
    }

    /// 静默态:收窄的双翼,只做信息显示
    static let wingWidth: CGFloat = 46
    static var collapsedWidth: CGFloat {
        notchWidth > 0 ? notchWidth + wingWidth * 2 : 152
    }
    /// 展开态:不受静默宽度束缚,可达 2.8 倍
    static var expandedWidth: CGFloat {
        min(collapsedWidth * 2.8, (screen?.frame.width ?? 1440) - 240)
    }

    // MARK: 生命周期

    func show() {
        if panel == nil { build() }
        model.refreshCounts()
        // 固定画布:宽 = 最大展开宽 + 边距,高 = 最大展开高;此后窗口永不移动/缩放
        if let panel, let screen = Self.screen {
            let size = NSSize(width: Self.expandedWidth + 32, height: 360)
            let f = screen.frame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                                  width: size.width, height: size.height), display: true)
            panel.invalidateShadow()
        }
        panel?.orderFrontRegardless()
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
    }

    func refresh() {
        model.refreshCounts()
    }

    func updateCoreSize(_ s: CGSize) {
        coreSize = s
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
        let h = IslandHostingView(rootView: view)
        h.coreSize = { [weak self] in self?.coreSize ?? .zero }
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false      // 阴影由 SwiftUI 按岛形绘制,窗口层永不产生方形阴影
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
        // 单一弹簧驱动整块岛体连续变形——慢一点,带自然回弹
        withAnimation(.spring(response: 0.6, dampingFraction: 0.76)) {
            model.mode = mode
        }
    }
}

// MARK: - 两分钟计时器(GTD 两分钟规则:点「马上做」即开始 2:00 倒计时)

@MainActor
final class TwoMinuteTimer {
    static let shared = TwoMinuteTimer()

    private var timer: Timer?
    private var itemId: Int64?
    private var title = ""
    private var remaining = 120

    var isActive: Bool { timer != nil }

    func start(itemId: Int64, title: String) {
        cancel()
        self.itemId = itemId
        self.title = title
        remaining = 120
        Telemetry.record(event: "two_min_start", itemId: itemId)
        IslandController.shared.model.twoMinText = "2:00"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in TwoMinuteTimer.shared.tick() }
        }
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            timeUp()
            return
        }
        IslandController.shared.model.twoMinText = String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func timeUp() {
        let id = itemId
        let t = title
        cancel()
        guard let id else { return }
        IslandController.shared.present(event: IslandEvent(
            icon: "bolt.fill", color: Theme.warning,
            title: "2 分钟到——搞定了吗?",
            subtitle: String(t.prefix(30)),
            actions: [
                IslandEvent.Action(label: "搞定 ✓", prominent: true) {
                    AppDatabase.shared.markItemDone(id)
                    Telemetry.record(event: "two_min_done", itemId: id)
                    IslandController.shared.refresh()
                },
                IslandEvent.Action(label: "还没,留着") {
                    Telemetry.record(event: "two_min_giveup", itemId: id)
                },
            ],
            duration: 25, kind: "two_min"))
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        itemId = nil
        IslandController.shared.model.twoMinText = nil
    }
}

// MARK: - 模型

@MainActor
final class IslandModel: ObservableObject {
    enum Mode { case collapsed, peek, event, drop }

    @Published var mode: Mode = .collapsed
    @Published var focusText: String? = nil
    @Published var twoMinText: String? = nil
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

    var isWorking: Bool { focusText != nil || twoMinText != nil }
    var isCalm: Bool { !isWorking && overdue == 0 && inboxCount == 0 && actionCount == 0 }

    /// 状态灯文本(peek 头部用)
    var statusLine: String {
        if let t = twoMinText { return "⚡ 马上做 · \(t)" }
        if let f = focusText { return f }
        if overdue > 0 { return "\(overdue) 条已到点" }
        if inboxCount >= 5 { return "收件箱 \(inboxCount)" }
        if actionCount > 0 { return "\(actionCount) 待办" }
        return ""
    }
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
    /// 高度略微突出菜单栏/刘海一点点,让粘连弧和存在感露出来
    private var collapsedHeight: CGFloat { notchInset > 0 ? notchInset + 5 : 30 }
    private var expandedWidth: CGFloat { IslandController.expandedWidth }

    var body: some View {
        core
            .background(GeometryReader { geo in
                Color.clear.preference(key: IslandSizeKey.self, value: geo.size)
            })
            .onPreferenceChange(IslandSizeKey.self) { size in
                Task { @MainActor in controller.updateCoreSize(size) }
            }
            // 钉在固定画布的顶部中央:变形全程窗口不动,岛体连续生长
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var core: some View {
        Group {
            switch model.mode {
            case .collapsed: collapsedView
            case .peek: peekView
            case .event: eventView
            case .drop: dropView
            }
        }
        .background(
            // 阴影跟随岛形绘制(静默态无影,与刘海无缝)
            islandShape.fill(Color.black
                .shadow(.drop(color: .black.opacity(model.mode == .collapsed ? 0 : 0.5),
                              radius: 16, y: 7)))
        )
        .overlay {
            if model.mode != .collapsed {
                islandShape.stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            }
        }
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

    private var islandShape: IslandShape {
        IslandShape(bottomRadius: model.mode == .collapsed ? 11 : 20)
    }

    // MARK: 右键菜单

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

    // MARK: 静默态:收窄双翼,纯信息显示

    private var collapsedView: some View {
        Group {
            if notchWidth > 0 {
                HStack(spacing: 0) {
                    leftWing.frame(width: IslandController.wingWidth)
                    Color.clear.frame(width: notchWidth)
                    rightWing.frame(width: IslandController.wingWidth)
                }
                .frame(height: collapsedHeight)
            } else {
                HStack(spacing: 8) {
                    leftWing
                    rightWing
                }
                .padding(.horizontal, 16)
                .frame(height: collapsedHeight)
                .frame(minWidth: IslandController.collapsedWidth)
            }
        }
        .transition(.opacity)
    }

    /// 左翼:正在做事(聚焦/两分钟)时像素标持续闪动;否则最高优先级状态标
    private var leftWing: some View {
        Group {
            if model.twoMinText != nil {
                WorkingGlyph(pattern: Pixel.bolt, color: Theme.warning)
            } else if model.focusText != nil {
                WorkingGlyph(pattern: Pixel.play, color: Theme.success)
            } else if model.overdue > 0 {
                PixelGlyph(pattern: Pixel.bell, color: Theme.danger, pixel: 1.9)
            } else if model.inboxCount >= 5 {
                PixelGlyph(pattern: Pixel.tray, color: Theme.warning, pixel: 1.9)
            } else if model.actionCount > 0 {
                PixelGlyph(pattern: Pixel.bolt, color: Color(red: 0.42, green: 0.62, blue: 1.0), pixel: 1.9)
            } else {
                PixelGlyph(pattern: Pixel.calm, color: .white.opacity(0.35), pixel: 1.9)
            }
        }
    }

    /// 右翼:倒计时(两分钟/聚焦)或紧凑指示灯
    private var rightWing: some View {
        Group {
            if let t = model.twoMinText {
                Text(t)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.warning)
            } else if let f = model.focusText {
                Text(shortCountdown(f))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.success)
            } else if model.isCalm {
                Circle().fill(Color.white.opacity(0.28)).frame(width: 4, height: 4)
            } else {
                compactIndicators
            }
        }
    }

    /// 紧凑指示灯:窄翼里最多放两盏,再多显示 +
    private var compactIndicators: some View {
        var lights: [(pattern: [String], color: Color, count: Int)] = []
        if model.overdue > 0 { lights.append((Pixel.bell, Theme.danger, model.overdue)) }
        if model.inboxCount > 0 { lights.append((Pixel.tray, Theme.warning, model.inboxCount)) }
        if model.actionCount > 0 { lights.append((Pixel.bolt, Color(red: 0.42, green: 0.62, blue: 1.0), model.actionCount)) }
        return HStack(spacing: 5) {
            ForEach(Array(lights.prefix(2).enumerated()), id: \.offset) { _, l in
                HStack(spacing: 2) {
                    PixelGlyph(pattern: l.pattern, color: l.color, pixel: 1.5)
                    Text(l.count > 99 ? "99" : "\(l.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(l.color.opacity(0.95))
                }
            }
            if lights.count > 2 {
                Text("+").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func shortCountdown(_ text: String) -> String {
        let parts = text.split(separator: " ")
        for p in parts where p.contains(":") { return String(p) }
        return String(text.prefix(6))
    }

    // MARK: 事件卡

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
                    .padding(.horizontal, 18)
                    .padding(.top, notchInset > 0 ? notchInset + 8 : 12)
                    .padding(.bottom, 10)
                    GeometryReader { geo in
                        Capsule()
                            .fill(e.color.opacity(0.55))
                            .frame(width: geo.size.width * model.eventProgress, height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 5)
                }
                .frame(width: expandedWidth)
            }
        }
        .transition(.opacity)
    }

    // MARK: 预览态

    private var peekView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                leftWing
                Text(model.statusLine.isEmpty ? "全部清空,心如止水 🧘" : model.statusLine)
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
        .padding(.horizontal, 18)
        .padding(.top, notchInset > 0 ? notchInset + 6 : 12)
        .padding(.bottom, 12)
        .frame(width: expandedWidth, alignment: .leading)
        .transition(.opacity)
    }

    /// 深色行动链:项目在前,内容在后;▶ 当前步,🔒 后置步
    private func darkChain(_ chain: TodoPreviewData.Chain) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(chain.steps.prefix(3).enumerated()), id: \.element.id) { idx, step in
                HStack(spacing: 6) {
                    if idx == 0 {
                        Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
                        Text(chain.projectName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.teal)
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
        .padding(.top, notchInset > 0 ? notchInset : 0)
        .frame(width: max(IslandController.collapsedWidth + 60, 280),
               height: max(42, collapsedHeight + 14))
        .background(
            islandShape.fill(LinearGradient(colors: [Color(red: 0.3, green: 0.5, blue: 1.0),
                                                     Color(red: 0.55, green: 0.35, blue: 0.95)],
                                            startPoint: .leading, endPoint: .trailing))
        )
        .transition(.opacity)
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

private struct IslandSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - 预览数据

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
