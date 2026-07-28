import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 桌面悬浮窗(§4.1 入口一):常驻置顶小方块。
/// 拖文件进来弹确认面板;点按 = 归档 Finder 当前选中项。
/// 不抢焦点(.nonactivatingPanel),可拖动换位,位置自动记忆。
@MainActor
final class DropWindowController {
    private var panel: NSPanel?
    private var previewPanel: NSPanel?
    private var hideTask: Task<Void, Never>?
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 悬停预览:整个项目表的待办逻辑(当前步 → 锁定的后置步)

    fileprivate func setHover(_ hovering: Bool) {
        hideTask?.cancel()
        if hovering {
            showPreview()
        } else {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if !Task.isCancelled { self?.hidePreview() }
            }
        }
    }

    private func showPreview() {
        hidePreview()
        let data = TodoPreviewData.build()
        guard !data.isEmpty else { return }

        let hosting = NSHostingView(rootView: TodoPreviewView(data: data))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true   // 纯预览,不截获鼠标
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting

        // 默认展开在圆点左侧;贴左边缘时翻到右侧,垂直方向对齐圆点并夹在屏幕内
        if let dot = panel, let screen = dot.screen ?? NSScreen.main {
            let f = dot.frame
            var x = f.minX - size.width - 10
            if x < screen.visibleFrame.minX + 8 { x = f.maxX + 10 }
            var y = f.midY - size.height / 2
            y = min(max(y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.orderFrontRegardless()
        previewPanel = p
        Telemetry.record(event: "dot_preview")
    }

    private func hidePreview() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }

    func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "dropWindowVisible")
    }

    func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "dropWindowVisible")
    }

    func toggle() { isVisible ? hide() : show() }

    private func build() {
        let size = NSSize(width: 64, height: 64)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false  // 阴影交给 SwiftUI,可随状态变化
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.setFrameAutosaveName("TidyDropDot")  // 换名避免恢复旧尺寸

        let view = DropTargetView(
            onDrop: { [weak self] urls in self?.onDrop?(urls) },
            onClick: { [weak self] in self?.hidePreview(); self?.onClick?() },
            onHoverChange: { [weak self] h in self?.setHover(h) })
        p.contentView = NSHostingView(rootView: view)

        // 首次启动放到屏幕右侧中部
        if p.frame.origin == .zero, let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.midY - size.height / 2))
        }
        panel = p
    }
}

/// 悬浮小圆点:平时安静的小图标,拖文件上来即归档,点一下展开项目工作台。
/// 角标显示当前待办数——它同时是「入口」和「状态灯」。
private struct DropTargetView: View {
    let onDrop: ([URL]) -> Void
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void
    @State private var targeted = false
    @State private var hovering = false
    @State private var badgeCount = 0

    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.98),
                                Color(red: 0.62, green: 0.40, blue: 0.95)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(gradient)
                    .opacity(targeted ? 0.95 : hovering ? 0.3 : 0.14)
                Image(systemName: targeted ? "tray.and.arrow.down.fill" : "archivebox.fill")
                    .font(.system(size: targeted ? 20 : 18, weight: .medium))
                    .foregroundStyle(targeted || hovering ? AnyShapeStyle(.white) : AnyShapeStyle(gradient))
                    .symbolEffect(.bounce, value: targeted)
            }
            .overlay(Circle().strokeBorder(gradient, lineWidth: targeted ? 2 : 1)
                .opacity(targeted ? 1 : hovering ? 0.7 : 0.4))
            .frame(width: 44, height: 44)
            // 待办角标:让"现在有几件事"抬眼可见
            if badgeCount > 0, !targeted {
                Text("\(min(badgeCount, 99))")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4.5).padding(.vertical, 1.5)
                    .background(Capsule().fill(.red))
                    .offset(x: 4, y: -3)
            }
        }
        .shadow(color: Color(red: 0.5, green: 0.45, blue: 0.95).opacity(targeted ? 0.5 : hovering ? 0.3 : 0.15),
                radius: targeted ? 14 : 8, y: 2)
        .scaleEffect(targeted ? 1.25 : hovering ? 1.12 : 1.0)
        .animation(.spring(duration: 0.28, bounce: 0.35), value: targeted)
        .animation(.spring(duration: 0.25), value: hovering)
        .frame(width: 64, height: 64)
        .contentShape(Circle().scale(1.3))
        .onHover { h in
            hovering = h
            if h { refreshBadge() }
            onHoverChange(h)
        }
        .onTapGesture { onClick() }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            collectFileURLs(from: providers) { urls in
                if !urls.isEmpty { onDrop(urls) }
            }
            return true
        }
        .onAppear {
            refreshBadge()
            Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
                Task { @MainActor in refreshBadge() }
            }
        }
        .help("拖文件来归档 · 点击打开工作台(⌥⌘P)")
    }

    private func refreshBadge() {
        badgeCount = AppDatabase.shared.inboxCaptures(limit: 50).count
            + AppDatabase.shared.globalNextActions(limit: 50).count
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

// MARK: - 悬停预览:待办逻辑一览

/// 预览数据:按项目分组的行动链 + 独立行动
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
        // 最紧迫的项目排前面
        data.chains.sort { ($0.steps.first?.urgency ?? 0) > ($1.steps.first?.urgency ?? 0) }
        data.chains = Array(data.chains.prefix(4))
        data.loose = Array(data.loose.prefix(3))
        return data
    }
}

/// 预览视图:当前步高亮 ▶,后置步骤带锁灰显,一眼看懂「先做什么、后面等着什么」
struct TodoPreviewView: View {
    let data: TodoPreviewData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                Text("接下来要做的").font(.system(size: 13, weight: .bold))
                Spacer()
                if data.doneToday > 0 {
                    Text("今日 ✓\(data.doneToday)").font(Theme.fontMicro).foregroundStyle(Theme.success)
                }
            }
            if data.chains.isEmpty && data.loose.isEmpty {
                Text(data.inboxCount > 0 ? "行动清单空着,但收件箱有 \(data.inboxCount) 条待理清(⌥⌘I)" : "全部清空,心如止水 🧘")
                    .font(Theme.fontSub).foregroundStyle(.secondary)
            }
            ForEach(Array(data.chains.enumerated()), id: \.offset) { _, chain in
                chainView(chain)
            }
            if !data.loose.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("独立行动").font(Theme.fontMicro).foregroundStyle(.tertiary)
                    ForEach(data.loose, id: \.id) { it in
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
                            Text(it.nextAction ?? it.title).font(Theme.fontSub).lineLimit(1)
                            if let r = it.remindAt {
                                Text(DateMention.format(r)).font(Theme.fontMicro)
                                    .foregroundStyle(r < Date() ? Theme.danger : Theme.warning)
                            }
                        }
                    }
                }
            }
            if data.inboxCount > 0, !(data.chains.isEmpty && data.loose.isEmpty) {
                Text("另有收件箱 \(data.inboxCount) 条待理清")
                    .font(Theme.fontMicro).foregroundStyle(Theme.warning)
            }
            Text("点击图标打开工作台 · ⌥⌘P")
                .font(Theme.fontMicro).foregroundStyle(.quaternary)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
    }

    /// 一个项目的行动链:▶ 当前步 → 🔒 后置步(灰显缩进,竖线相连)
    private func chainView(_ chain: TodoPreviewData.Chain) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(Theme.teal)
                Text(chain.projectName).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.teal)
            }
            ForEach(Array(chain.steps.enumerated()), id: \.element.id) { idx, step in
                HStack(spacing: 6) {
                    if idx == 0 {
                        Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    } else {
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 12)
                                .padding(.leading, 4).padding(.trailing, 5)
                            Image(systemName: chain.hasSequence ? "lock.fill" : "circle.dotted")
                                .font(.system(size: 8)).foregroundStyle(.quaternary)
                        }
                    }
                    Text(step.nextAction ?? step.title)
                        .font(.system(size: idx == 0 ? 12.5 : 11, weight: idx == 0 ? .medium : .regular))
                        .foregroundStyle(idx == 0 ? .primary : .tertiary)
                        .lineLimit(1)
                    if idx == 0, let r = step.remindAt {
                        Text(DateMention.format(r)).font(Theme.fontMicro)
                            .foregroundStyle(r < Date() ? Theme.danger : Theme.warning)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, idx == 0 ? 2 : 8)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.05)))
    }
}
