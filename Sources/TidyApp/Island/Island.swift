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
    static let star = [    // Tidy 像素 Logo(顶带左上角)
        "..X..",
        ".XXX.",
        "XX.XX",
        ".XXX.",
        "..X..",
    ]
    static let creatureA = [   // 任务行的像素小生物(两帧走路)
        ".X.X.X.",
        "XXXXXXX",
        "X.XXX.X",
        "XXXXXXX",
        ".X...X.",
    ]
    static let creatureB = [
        ".X.X.X.",
        "XXXXXXX",
        "X.XXX.X",
        "XXXXXXX",
        "X..X..X",
    ]
}

/// 任务行小生物:两帧动画,颜色标识项目身份(同项目同色)
struct CreatureGlyph: View {
    var color: Color
    var pixel: CGFloat = 1.7

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { tl in
            let a = Int(tl.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            PixelGlyph(pattern: a ? Pixel.creatureA : Pixel.creatureB, color: color, pixel: pixel)
        }
    }
}

/// 像素电量条:竖排格,自下而上点亮 = 行动链完成进度
struct PixelBar: View {
    var filled: Int
    var total: Int
    var color: Color

    var body: some View {
        let segs = min(max(total, 1), 6)
        let lit = total > 0 ? Int((Double(filled) / Double(total) * Double(segs)).rounded()) : 0
        VStack(spacing: 1.5) {
            ForEach((0..<segs).reversed(), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? color : Color.white.opacity(0.14))
                    .frame(width: 5, height: 3)
            }
        }
        .help("已完成 \(filled)/\(total) 步")
    }
}

/// 项目名 → 稳定的像素色(同项目每次同色)
func projectHue(_ name: String) -> Color {
    var h: UInt32 = 5381
    for u in name.unicodeScalars { h = h &* 33 &+ u.value }
    return Color(hue: Double(h % 330) / 360.0, saturation: 0.55, brightness: 0.92)
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
    /// 按当前模式解析可点区(不依赖测量回传):折叠 = 胶囊区域;展开 = 整张画布
    var activeRect: (NSRect) -> NSRect = { $0 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return activeRect(bounds).contains(p) ? super.hitTest(point) : nil
    }

    required init(rootView: IslandView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("unsupported") }
}

// MARK: - 音效(8-bit 气质的系统短音,可开关)

@MainActor
enum SoundFX {
    static func play(_ name: String) {
        guard IslandController.shared.model.soundOn else { return }
        NSSound(named: name)?.play()
    }
    static func event() { play("Tink") }      // 事件卡到达
    static func tap() { play("Pop") }         // 按钮操作
    static func drop() { play("Bottle") }     // 拖拽入靶
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
    static let wingWidth: CGFloat = 54
    static var collapsedWidth: CGFloat {
        notchWidth > 0 ? notchWidth + wingWidth * 2 : 160
    }
    /// 展开态:静默宽度的 ~2.3 倍(舒展一些,信息密度优先)
    static var expandedWidth: CGFloat {
        min(collapsedWidth * 2.3, (screen?.frame.width ?? 1440) - 200)
    }

    // MARK: 生命周期

    func show() {
        if panel == nil { build() }
        model.refreshCounts()
        // 固定画布:宽 = 最大展开宽 + 边距,高 = 最大展开高;此后窗口永不移动/缩放
        if let panel, let screen = Self.screen {
            let size = NSSize(width: Self.expandedWidth + 32, height: 400)
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
            model.queuedEvents = eventQueue.count
            return
        }
        showEvent(event)
    }

    private func showEvent(_ e: IslandEvent) {
        model.event = e
        model.eventProgress = 1
        SoundFX.event()
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
            model.queuedEvents = eventQueue.count
            showEvent(next)
        } else {
            model.queuedEvents = 0
            setMode(.collapsed)
            refresh()
        }
    }

    func runEventAction(_ action: IslandEvent.Action) {
        Telemetry.record(event: "island_action", chosenPath: action.label)
        SoundFX.tap()
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
        h.activeRect = { [weak self] bounds in
            guard let self else { return .zero }
            switch self.model.mode {
            case .peek, .event, .drop:
                return bounds        // 展开态整张画布可交互(空白处点击 = 打开工作台)
            case .collapsed:
                let w = Self.collapsedWidth + 8
                let hgt = (Self.notchInset > 0 ? Self.notchInset + 5 : 30) + 6
                // NSHostingView 是 flipped 坐标,岛体贴顶
                return NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: hgt)
            }
        }
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
            SoundFX.drop()
            setMode(.drop)
        } else {
            setMode(model.event != nil ? .event : .collapsed)
        }
    }

    /// 全岛唯一的形变弹簧:身体、内容过渡共用同一条曲线,保证完全同步
    static let morph = Animation.spring(response: 0.45, dampingFraction: 0.8)

    private func setMode(_ mode: IslandModel.Mode) {
        guard model.mode != mode else { return }
        if mode != .peek { model.preview = nil }
        withAnimation(Self.morph) {
            model.mode = mode
        }
    }

    /// 齿轮按钮:在鼠标处弹出完整菜单(与右键菜单同源)
    func showSettingsMenu() {
        guard let hosting, let panel else { return }
        let menu = IslandMenuBridge.shared.buildMenu(model: model)
        let loc = hosting.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: loc, in: hosting)
    }
}

/// NSMenu 需要 target/selector,用桥接对象把菜单项接到 AppActions
@MainActor
final class IslandMenuBridge: NSObject {
    static let shared = IslandMenuBridge()

    func buildMenu(model: IslandModel) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            m.addItem(item)
        }
        add("打开工作台\t⌥⌘P", #selector(workbench))
        add("快速捕获\t⌥⌘N", #selector(capture))
        add("理清收件箱(\(model.inboxCount))\t⌥⌘I", #selector(clarify))
        add("归档 Finder 选中项\t⌥⌘A", #selector(archive))
        add("关联 Finder 选中的文档…", #selector(linkDocs))
        if FocusManager.shared.isActive {
            add("结束聚焦…", #selector(endFocus))
        }
        m.addItem(.separator())
        add("每周复盘…", #selector(review))
        add("统计", #selector(stats))
        add("新手指引", #selector(onboarding))
        m.addItem(.separator())
        let styleMenu = NSMenu()
        for (i, name) in ["素黑", "颗粒", "天光"].enumerated() {
            let it = NSMenuItem(title: name, action: #selector(setStyle(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = model.style == i ? .on : .off
            styleMenu.addItem(it)
        }
        let styleItem = NSMenuItem(title: "质感", action: nil, keyEquivalent: "")
        m.addItem(styleItem)
        m.setSubmenu(styleMenu, for: styleItem)
        let dyn = NSMenuItem(title: "动态图标", action: #selector(toggleDyn), keyEquivalent: "")
        dyn.target = self
        dyn.state = IslandController.shared.model.dynamicIcons ? .on : .off
        m.addItem(dyn)
        let stretch = NSMenuItem(title: "久坐提醒(每 50 分钟)",
                                 action: #selector(toggleStretch), keyEquivalent: "")
        stretch.target = self
        stretch.state = ReviewScheduler.shared.stretchOn ? .on : .off
        m.addItem(stretch)
        add("AI 设置(.env)…", #selector(openEnv))
        add("编辑 MEMORY.md", #selector(openMemory))
        add("自检…", #selector(selfCheck))
        m.addItem(.separator())
        add("隐藏灵动岛 1 小时", #selector(hideIsland))
        add("退出 Tidy", #selector(quit))
        return m
    }

    @objc private func workbench() { AppActions.workbench() }
    @objc private func capture() { AppActions.capture() }
    @objc private func clarify() { AppActions.clarify() }
    @objc private func archive() { AppActions.archiveFinder() }
    @objc private func linkDocs() { AppActions.linkDocs() }
    @objc private func endFocus() { AppActions.endFocus() }
    @objc private func review() { AppActions.review() }
    @objc private func stats() { AppActions.stats() }
    @objc private func onboarding() { AppActions.onboarding() }
    @objc private func openEnv() { AppActions.openEnv() }
    @objc private func openMemory() { AppActions.openMemory() }
    @objc private func selfCheck() { AppActions.selfCheck() }
    @objc private func hideIsland() { IslandController.shared.hideTemporarily() }
    @objc private func quit() { AppActions.quit() }
    @objc private func toggleDyn() {
        IslandController.shared.model.toggleDynamicIcons()
    }
    @objc private func toggleStretch() {
        ReviewScheduler.shared.stretchOn.toggle()
    }
    @objc private func setStyle(_ sender: NSMenuItem) {
        IslandController.shared.model.style = sender.tag
        UserDefaults.standard.set(sender.tag, forKey: "islandStyle")
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

    func isRunning(for id: Int64) -> Bool { timer != nil && itemId == id }

    func start(itemId: Int64, title: String) {
        cancel()
        self.itemId = itemId
        self.title = title
        remaining = 120
        Telemetry.record(event: "two_min_start", itemId: itemId)
        // 两分钟内的事移出常规流程:不进收件箱、不进清单、不弹草稿卡
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET status = 'clarified', gtdList = 'doing', updatedAt = ? WHERE id = ?",
                           arguments: [Date(), itemId])
        }
        IslandController.shared.refresh()
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
                // 搞定 = 只留一条记录供周复盘/总结,不进任何后续流程
                IslandEvent.Action(label: "搞定 ✓", prominent: true) {
                    AppDatabase.shared.markItemDone(id)
                    Telemetry.record(event: "two_min_done", itemId: id)
                    MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) ⚡ 两分钟即办:\(t.prefix(40))")
                    IslandController.shared.refresh()
                },
                // 没搞定 = 这才进入正常流程(回收件箱,已有 AI 草稿的直接可采纳)
                IslandEvent.Action(label: "没搞定,进待办") {
                    Telemetry.record(event: "two_min_giveup", itemId: id)
                    try? AppDatabase.shared.dbQueue.write { db in
                        try db.execute(sql: "UPDATE item SET status = 'inbox', gtdList = NULL, updatedAt = ? WHERE id = ?",
                                       arguments: [Date(), id])
                    }
                    IslandController.shared.refresh()
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
    @Published var queuedEvents = 0      // 排队中的事件卡数(vibeisland 式 +N 角标)
    @Published var soundOn = UserDefaults.standard.object(forKey: "islandSound") as? Bool ?? true
    @Published var style = UserDefaults.standard.integer(forKey: "islandStyle")  // 0 素黑 1 颗粒 2 天光
    @Published var dynamicIcons = UserDefaults.standard.object(forKey: "dynIcons") as? Bool ?? true

    func toggleDynamicIcons() {
        dynamicIcons.toggle()
        UserDefaults.standard.set(dynamicIcons, forKey: "dynIcons")
    }
    var eventHovering = false

    func toggleSound() {
        soundOn.toggle()
        UserDefaults.standard.set(soundOn, forKey: "islandSound")
        if soundOn { NSSound(named: "Pop")?.play() }
    }

    func cycleStyle() {
        style = (style + 1) % 3
        UserDefaults.standard.set(style, forKey: "islandStyle")
    }

    var styleName: String { ["素黑", "颗粒", "天光"][style] }

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
        // 钉在固定画布的顶部中央:变形全程窗口不动,岛体连续生长
        core.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            // 视觉变量层(裁剪进岛形,不拦截交互)
            Group {
                if model.style == 1 { GrainOverlay() }
                else if model.style == 2 { GodRayOverlay() }
            }
            .clipShape(islandShape)
        }
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
        Button("关联 Finder 选中的文档…") { AppActions.linkDocs() }
        Divider()
        Menu("质感:\(model.styleName)") {
            ForEach(0..<3, id: \.self) { i in
                Button(["素黑", "颗粒", "天光"][i]) {
                    model.style = i
                    UserDefaults.standard.set(i, forKey: "islandStyle")
                }
            }
        }
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
                    leftWing.frame(width: IslandController.wingWidth).clipped()
                    Color.clear.frame(width: notchWidth)
                    rightWing.frame(width: IslandController.wingWidth).clipped()
                }
                .frame(height: collapsedHeight)
            } else {
                HStack(spacing: 8) {
                    leftWing
                    rightWing
                }
                .padding(.horizontal, 16)
                .frame(height: collapsedHeight)
                .frame(width: IslandController.collapsedWidth)
                .clipped()   // 状态信息绝不越过岛体边缘
            }
        }
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity).animation(IslandController.morph))
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

    /// 紧凑指示灯:窄翼空间用"时分复用"——每 3.5 秒轮播一个维度,
    /// 小空间也能看全所有状态(状态栏式的常态信息提示)
    private var compactIndicators: some View {
        var lights: [(pattern: [String], color: Color, count: Int)] = []
        if model.overdue > 0 { lights.append((Pixel.bell, Theme.danger, model.overdue)) }
        if model.inboxCount > 0 { lights.append((Pixel.tray, Theme.warning, model.inboxCount)) }
        if model.actionCount > 0 { lights.append((Pixel.bolt, Color(red: 0.42, green: 0.62, blue: 1.0), model.actionCount)) }
        return TimelineView(.periodic(from: .now, by: 3.5)) { tl in
            if lights.isEmpty {
                Circle().fill(Color.white.opacity(0.28)).frame(width: 4, height: 4)
            } else {
                let idx = Int(tl.date.timeIntervalSinceReferenceDate / 3.5) % lights.count
                let l = lights[idx]
                HStack(spacing: 4) {
                    PixelGlyph(pattern: l.pattern, color: l.color, pixel: 1.6)
                    Text(l.count > 99 ? "99" : "\(l.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(l.color.opacity(0.95))
                        .lineLimit(1)
                    if lights.count > 1 {
                        // 轮播位置点:几盏灯、现在是第几盏
                        HStack(spacing: 1.5) {
                            ForEach(0..<lights.count, id: \.self) { i in
                                Circle().fill(Color.white.opacity(i == idx ? 0.6 : 0.2))
                                    .frame(width: 2.5, height: 2.5)
                            }
                        }
                    }
                }
                .id(idx)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: idx)
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
                        if model.queuedEvents > 0 {
                            Text("+\(model.queuedEvents)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
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
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity).animation(IslandController.morph))
    }

    // MARK: 预览态

    private var peekView: some View {
        VStack(alignment: .leading, spacing: 7) {
            peekHeader
            peekBody
        }
        .padding(.bottom, 14)
        .frame(width: expandedWidth, alignment: .leading)
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity).animation(IslandController.morph))
    }

    /// 顶带(vibeisland 式):左 = 像素 Logo + 彩色数字统计;右 = ✓今日 + 喇叭 + 齿轮。
    /// 刘海机型分列两侧横带,紧贴屏幕上缘。
    private var peekHeader: some View {
        Group {
            if notchWidth > 0 {
                let side = max(60, (expandedWidth - notchWidth) / 2)
                HStack(spacing: 0) {
                    headerStats
                        .padding(.leading, 20)
                        .frame(width: side, alignment: .leading)
                    Color.clear.frame(width: notchWidth)
                    headerControls
                        .padding(.trailing, 20)
                        .frame(width: side, alignment: .trailing)
                }
                .frame(height: collapsedHeight)
            } else {
                HStack {
                    headerStats
                    Spacer()
                    headerControls
                }
                .padding(.horizontal, 16)
                .frame(height: 28)
                .padding(.top, 2)
            }
        }
    }

    /// 左统计带:Logo + 数字(等宽字,彩色高亮,灰色分隔)
    private var headerStats: some View {
        HStack(spacing: 7) {
            if model.twoMinText != nil {
                WorkingGlyph(pattern: Pixel.bolt, color: Theme.warning, pixel: 1.7)
            } else if model.focusText != nil {
                WorkingGlyph(pattern: Pixel.play, color: Theme.success, pixel: 1.7)
            } else {
                PixelGlyph(pattern: Pixel.star, color: Color(red: 1.0, green: 0.58, blue: 0.2), pixel: 1.9)
            }
            Group {
                // 多状态并列:两分钟 + 聚焦可同时显示,再接常规计数
                if let t = model.twoMinText {
                    statNum(t, Theme.warning)
                    statLabel("马上做")
                }
                if let f = model.focusText {
                    if model.twoMinText != nil { statDivider }
                    statNum(shortCountdown(f), Theme.success)
                    statLabel("聚焦")
                }
                if model.isWorking {
                    if model.actionCount > 0 {
                        statDivider
                        statNum("\(model.actionCount)", Color(red: 0.42, green: 0.62, blue: 1.0))
                        statLabel("待办")
                    }
                } else {
                    if model.actionCount > 0 {
                        statNum("\(model.actionCount)", Color(red: 0.42, green: 0.62, blue: 1.0))
                        statLabel("待办")
                    }
                    if model.inboxCount > 0 {
                        if model.actionCount > 0 { statDivider }
                        statNum("\(model.inboxCount)", Theme.warning)
                        statLabel("收件箱")
                    }
                    if model.overdue > 0 {
                        statDivider
                        statNum("\(model.overdue)", Theme.danger)
                        statLabel("到点")
                    }
                    if model.isCalm {
                        statLabel("心如止水 🧘")
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private func statNum(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(c)
    }
    private func statLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
    }
    private var statDivider: some View {
        Text("|").font(.system(size: 10)).foregroundStyle(.white.opacity(0.2))
    }

    /// 右控制带:✓今日 · 喇叭 · 齿轮
    private var headerControls: some View {
        HStack(spacing: 13) {
            if let d = model.preview, d.doneToday > 0 {
                HStack(spacing: 3) {
                    statNum("✓\(d.doneToday)", Theme.success)
                }
            }
            Button {
                model.toggleSound()
            } label: {
                Image(systemName: model.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.soundOn ? 0.85 : 0.4))
            }
            .buttonStyle(.plain)
            .help(model.soundOn ? "关闭音效" : "打开音效")
            Button {
                SoundFX.tap()
                controller.showSettingsMenu()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("菜单(工作台/理清/设置…)")
        }
    }

    @ViewBuilder
    private var peekBody: some View {
        Group {
            if let data = model.preview {
                let rows = peekRows(data)
                if rows.isEmpty {
                    Text(data.inboxCount > 0
                         ? "行动清单空着,收件箱有 \(data.inboxCount) 条待理清(⌥⌘I)"
                         : "没有待办。⌥⌘N 捕获想法,拖文件到这里归档")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 7) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            taskCard(row)
                        }
                    }
                    let hidden = data.totalOpen - rows.count
                    if hidden > 0 || data.inboxCount > 0 {
                        HStack(spacing: 8) {
                            if hidden > 0 {
                                Text("还有 \(hidden) 条 · 工作台查看")
                                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                            }
                            if data.inboxCount > 0 {
                                Text("收件箱 \(data.inboxCount) 待理清")
                                    .font(.system(size: 10)).foregroundStyle(Theme.warning.opacity(0.85))
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)   // 文字与岛缘之间留足呼吸
    }

    /// 预览行:同一项目合并;主行 = 图标+白题+灰说明,子行 = 列出后续步骤。
    private struct PeekRow {
        struct Step {
            var text: String
            var remindAt: Date?
        }
        var project: String?
        var text: String          // 白色题目(项目名或行动)
        var detail: String        // 灰色说明(当前步/期望结果)
        var remindAt: Date?
        var quadrant: Int         // 0 急重 1 重要 2 紧急 3 其余
        var doneSteps = 0
        var totalAll = 0
        var subSteps: [Step] = [] // 多步骤任务:把步骤列出来
        var active = false        // 正在聚焦的项目 → 动态图标
        var overdue: Bool { remindAt.map { $0 < Date() } ?? false }
    }

    private func quadrantOf(_ it: Item) -> Int {
        let imp = (it.importance ?? 0) >= 1, urg = (it.urgency ?? 0) >= 1
        switch (imp, urg) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return 2
        case (false, false): return 3
        }
    }

    private func peekRows(_ data: TodoPreviewData) -> [PeekRow] {
        let focusLeaf = FocusManager.shared.activeProjectPath?.components(separatedBy: "/").last
        var rows: [PeekRow] = []
        for chain in data.chains {
            guard let first = chain.steps.first else { continue }
            rows.append(PeekRow(project: chain.projectName,
                                text: chain.projectName,
                                detail: first.nextAction ?? first.title,
                                remindAt: first.remindAt,
                                quadrant: quadrantOf(first),
                                doneSteps: chain.doneSteps,
                                totalAll: chain.doneSteps + chain.totalSteps,
                                subSteps: chain.steps.dropFirst().map {
                                    PeekRow.Step(text: $0.nextAction ?? $0.title, remindAt: $0.remindAt)
                                },
                                active: chain.projectName == focusLeaf))
        }
        for it in data.loose {
            rows.append(PeekRow(project: nil,
                                text: it.nextAction ?? it.title,
                                detail: it.expectedOutcome?.isEmpty == false ? "→ \(it.expectedOutcome!)" : "独立行动",
                                remindAt: it.remindAt,
                                quadrant: quadrantOf(it)))
        }
        // 四象限排序:急重 → 重要 → 紧急 → 其余;同象限内先到点的在前
        rows.sort {
            if $0.quadrant != $1.quadrant { return $0.quadrant < $1.quadrant }
            return ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture)
        }
        var out = Array(rows.prefix(6))
        // 行数预算:行多时收敛子步骤,保证一屏放得下
        let subBudget = out.count <= 2 ? 3 : (out.count <= 4 ? 2 : 0)
        for i in out.indices { out[i].subSteps = Array(out[i].subSteps.prefix(subBudget)) }
        return out
    }

    /// 象限标签
    private func quadrantChip(_ q: Int) -> some View {
        Group {
            switch q {
            case 0: metaChip("急·重", Theme.danger)
            case 1: metaChip("重要", Theme.accent)
            case 2: metaChip("紧急", Theme.warning)
            default: EmptyView()
            }
        }
    }

    /// 任务主行:[图标] 白色题目  灰色说明 ……… [象限] [时间] [电量条 n/N]
    /// 子行:列出后续步骤(锁定灰显)。
    private func taskCard(_ row: PeekRow) -> some View {
        let hue = row.project.map(projectHue) ?? Color(red: 0.42, green: 0.62, blue: 1.0)
        return VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 8) {
                if row.active {
                    WorkingGlyph(pattern: Pixel.play, color: Theme.success, pixel: 1.7)
                } else if model.dynamicIcons {
                    CreatureGlyph(color: hue)
                } else {
                    PixelGlyph(pattern: Pixel.creatureA, color: hue, pixel: 1.7)
                }
                Text(row.text)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .layoutPriority(2)
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                quadrantChip(row.quadrant)
                if let r = row.remindAt {
                    metaChip(DateMention.format(r), row.overdue ? Theme.danger : Theme.warning)
                }
                if row.totalAll > 1 {
                    HStack(spacing: 3) {
                        PixelBar(filled: row.doneSteps, total: row.totalAll, color: hue)
                        Text("\(row.doneSteps)/\(row.totalAll)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            ForEach(Array(row.subSteps.enumerated()), id: \.offset) { idx, step in
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7)).foregroundStyle(.white.opacity(0.25))
                    Text("\(idx + 2). \(step.text)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                    if let r = step.remindAt {
                        Text(DateMention.format(r))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.warning.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 21)
            }
        }
    }

    /// 彩色小方标签(参考图右侧的 tag chips)
    private func metaChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(0.16)))
            .lineLimit(1)
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
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity).animation(IslandController.morph))
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

// MARK: - 视觉变量(vibeisland 式质感层)

/// 颗粒噪点:确定性伪随机,静态细腻噪纹
struct GrainOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 1000) / 1000
            }
            let count = min(Int(size.width * size.height / 130), 500)
            for _ in 0..<count {
                let x = rnd() * size.width
                let y = rnd() * size.height
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                         with: .color(.white.opacity(0.04 + 0.05 * rnd())))
            }
        }
        .allowsHitTesting(false)
    }
}

/// 顶部天光:从上缘洒下的一束微光
struct GodRayOverlay: View {
    var body: some View {
        RadialGradient(colors: [.white.opacity(0.13), .clear],
                       center: .top, startRadius: 0, endRadius: 190)
            .allowsHitTesting(false)
    }
}

// MARK: - 预览数据

struct TodoPreviewData {
    struct Chain {
        let projectName: String
        let steps: [Item]
        let hasSequence: Bool
        let totalSteps: Int
        let doneSteps: Int     // 链上已完成步数(像素电量条)
    }
    var chains: [Chain] = []
    var loose: [Item] = []
    var inboxCount = 0
    var doneToday = 0
    var totalOpen = 0     // 合并后的可见任务总数(项目算 1 条 + 独立行动各 1 条)

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
        let doneCounts = db.doneStepCounts()
        for (pid, steps) in grouped {
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
                                     hasSequence: sorted.contains { $0.seq != nil },
                                     totalSteps: sorted.count,
                                     doneSteps: doneCounts[pid] ?? 0))
        }
        data.chains.sort { ($0.steps.first?.urgency ?? 0) > ($1.steps.first?.urgency ?? 0) }
        data.totalOpen = data.chains.count + data.loose.count
        data.chains = Array(data.chains.prefix(6))
        data.loose = Array(data.loose.prefix(6))
        return data
    }
}
