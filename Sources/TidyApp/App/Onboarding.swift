import AppKit
import SwiftUI

/// 新手指引:传达 GTD 的核心思想——不是「做完所有事」,而是「把事情处理好」,
/// 把事务逻辑交给系统,人只关注眼前的一件事。
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?

    /// 首次启动自动展示
    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "onboardingShown") else { return }
        UserDefaults.standard.set(true, forKey: "onboardingShown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.present()
        }
    }

    func present() {
        close()
        Telemetry.record(event: "onboarding_open")
        let view = OnboardingView(onClose: { [weak self] in self?.close() },
                                  onTryCapture: { [weak self] in self?.close(); AppActions.capture() })
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
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
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - hosting.fittingSize.width / 2,
                                           y: f.minY + f.height * 0.86))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            if event.keyCode == 53 || event.keyCode == 36 { self.close(); return nil }
            return event
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct OnboardingView: View {
    let onClose: () -> Void
    let onTryCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 核心思想
            HStack(spacing: 10) {
                IconBadge(systemName: "brain.head.profile", color: Theme.violet, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("把事情处理好,而不是记住所有事")
                        .font(.system(size: 17, weight: .bold))
                    Text("GTD 的核心:大脑是用来产生想法的,不是用来存放想法的。")
                        .font(Theme.fontSub).foregroundStyle(.secondary)
                }
            }

            // 三条心法
            VStack(alignment: .leading, spacing: 9) {
                principle("1", "冒出任何念头,双击 ⌘ 扔进来,立刻忘掉它",
                          "捕获的意义是清空大脑。别分类、别判断,交给系统,继续手头的事。(⌥⌘N 同效;全局生效需在岛菜单开启辅助功能)", Theme.warning)
                principle("2", "理清时你只做「确认」,AI 已替你想好一半",
                          "每条想法只过一次脑子:是任务还是想法?下一步是什么?能 2 分钟做完就现在做。剩下的一键采纳。", Theme.violet)
                principle("3", "永远只看「下一步行动」,后面的事系统替你锁着",
                          "项目再复杂,当下能做的只有一步。做完一步,下一步自动解锁——你永远不需要在脑子里维护整张计划表。", Theme.accent)
            }

            Divider()

            // 动线 + 快捷键
            VStack(alignment: .leading, spacing: 7) {
                flowLine("tray.and.arrow.down.fill", Theme.warning, "收集", "双击 ⌘(或 ⌥⌘N)记想法 · 拖文件到灵动岛归档(⌥⌘A 归档 Finder 选中)")
                flowLine("wand.and.stars", Theme.violet, "理清", "⌥⌘I 逐条确认 AI 草稿,收件箱清零")
                flowLine("square.grid.2x2.fill", Theme.accent, "组织", "自动进入 行动/等待/搁置 清单;项目任务用「AI 拆解」生成行动链")
                flowLine("timer", Theme.success, "执行", "⌥⌘P 打开工作台,看「现在该做什么」,点 ▶ 进入 25 分钟聚焦")
                flowLine("sparkle.magnifyingglass", Theme.teal, "回顾", "系统定时提醒:待办半天一次 · 搁置每周扫一眼 · 周五复盘")
            }

            HStack(spacing: 8) {
                Image(systemName: "capsule.fill").foregroundStyle(.secondary).font(.system(size: 12))
                Text("屏幕顶部的灵动岛 = 状态灯:显示待办数/聚焦倒计时,悬停预览接下来要做的事,点击打开工作台,拖文件上去即归档")
                    .font(Theme.fontCaption).foregroundStyle(.secondary)
            }

            HStack {
                Text("随时可从菜单栏「新手指引」再次打开")
                    .font(Theme.fontMicro).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    onTryCapture()
                } label: { Label("试一下:捕获第一条想法", systemImage: "lightbulb.fill") }
                    .controlSize(.small)
                Button("开始使用 ↵", action: onClose)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(20)
        .panelChrome(width: 640)
    }

    private func principle(_ n: String, _ title: String, _ detail: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(color.opacity(0.15)))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(Theme.fontCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func flowLine(_ icon: String, _ color: Color, _ name: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
                .frame(width: 18)
            Text(name).font(.system(size: 12, weight: .semibold)).frame(width: 32, alignment: .leading)
            Text(desc).font(Theme.fontCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
