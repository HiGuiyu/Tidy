import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dropWindow = DropWindowController()
    private var env = EnvConfig.load()
    private var aiClient: OpenAIClient?
    private var selfCheckResults: [SelfCheck.Result] = []
    private var selfCheckMenuItem: NSMenuItem!
    private var inboxMenuItem: NSMenuItem!
    private var focusMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 自定义 PARA 根目录(.env 的 PARA_ROOT)
        if let custom = env.paraRoot, !custom.isEmpty {
            ParaTree.root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        // 基础设施:目录、记忆基础层、数据库(首次访问即建表)
        try? ParaTree.shared.ensureRoot()
        MemoryStore.shared.ensureFiles()
        MemoryStore.shared.syncFromFiles()
        _ = AppDatabase.shared

        // 预热(§4.5.6):启动即扫描目录树,首次拖拽即命中
        ParaTree.shared.scan()

        // AI 客户端注入
        let client = OpenAIClient(config: env)
        aiClient = client
        ArchivePanelController.shared.aiClient = client
        ClarifyController.shared.aiClient = client
        PlanController.shared.aiClient = client
        ArchivePanelController.shared.activeProjectPathProvider = { FocusManager.shared.activeProjectPath }

        // 定期提醒:待办半天一次、收件箱每日、搁置每周、每周复盘、单条到点提醒
        ReviewScheduler.shared.start()

        // 全局动作注册:让工作台流程条能直接触发捕获/归档
        AppActions.capture = { [weak self] in self?.showCapture() }
        AppActions.archiveFinder = { [weak self] in self?.archiveFromFinder() }

        setupStatusItem()
        setupDropWindow()
        setupHotKeys()
        setupFocusTicker()
        runSelfCheck()
        OnboardingController.shared.showIfFirstLaunch()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "TidyApp")
        }
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "归档 Finder 选中项", action: #selector(archiveFromFinder), keyEquivalent: "")
        menu.addItem(withTitle: "快速捕获想法", action: #selector(showCapture), keyEquivalent: "")
        menu.addItem(withTitle: "项目工作台", action: #selector(showWorkbench), keyEquivalent: "")
        menu.addItem(withTitle: "撤销上次归档", action: #selector(undoLast), keyEquivalent: "")
        menu.addItem(.separator())

        focusMenuItem = NSMenuItem(title: "结束聚焦…", action: #selector(endFocus), keyEquivalent: "")
        menu.addItem(focusMenuItem)

        let toggleDrop = NSMenuItem(title: "显示/隐藏悬浮窗", action: #selector(toggleDropWindow), keyEquivalent: "")
        menu.addItem(toggleDrop)
        menu.addItem(.separator())

        inboxMenuItem = NSMenuItem(title: "收件箱", action: #selector(startClarify), keyEquivalent: "")
        menu.addItem(inboxMenuItem)
        menu.addItem(withTitle: "打开 0-Inbox 目录", action: #selector(openInbox), keyEquivalent: "")
        menu.addItem(withTitle: "每周复盘…", action: #selector(showReview), keyEquivalent: "")
        menu.addItem(withTitle: "新手指引(GTD 心法)…", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(withTitle: "统计…", action: #selector(showStats), keyEquivalent: "")
        selfCheckMenuItem = NSMenuItem(title: "自检:运行中…", action: #selector(showSelfCheck), keyEquivalent: "")
        menu.addItem(selfCheckMenuItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "AI 设置(.env)…", action: #selector(openEnvSettings), keyEquivalent: "")
        menu.addItem(withTitle: "编辑 MEMORY.md(归档规则)", action: #selector(openMemoryFile), keyEquivalent: "")
        menu.addItem(withTitle: "编辑 USER.md(用户画像)", action: #selector(openUserFile), keyEquivalent: "")
        menu.addItem(withTitle: "打开 PARA 目录", action: #selector(openPara), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "⌥⌘A 归档 · ⌥⌘N 捕获 · ⌥⌘I 理清 · ⌥⌘P 工作台 · ⌥⌘Z 撤销", action: nil, keyEquivalent: "")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(withTitle: "Tidy v\(version) · 开源(MIT)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let n = AppDatabase.shared.inboxCaptures().count
        inboxMenuItem.title = n > 0 ? "理清收件箱(\(n) 条待理清)…" : "收件箱:已清空 ✓"
        focusMenuItem.isHidden = !FocusManager.shared.isActive
        // 记忆文件被手工编辑过则重新同步(基础层是文本文件,§4.5.1)
        MemoryStore.shared.syncFromFiles()
    }

    // MARK: - 悬浮窗 / 快捷键 / 聚焦

    private func setupDropWindow() {
        dropWindow.onDrop = { urls in
            ArchivePanelController.shared.present(files: urls)
        }
        // 点击悬浮点 = 展开项目工作台(归档 Finder 选中项走 ⌥⌘A)
        dropWindow.onClick = { WorkbenchController.shared.toggle() }
        if UserDefaults.standard.object(forKey: "dropWindowVisible") as? Bool ?? true {
            dropWindow.show()
        }
    }

    private func setupHotKeys() {
        HotKeyManager.shared.registerAll(
            archive: { [weak self] in self?.archiveFromFinder() },
            capture: { [weak self] in self?.showCapture() },
            workbench: { WorkbenchController.shared.toggle() },
            undo: { [weak self] in self?.undoLast() },
            clarify: { ClarifyController.shared.startQueue() })
    }

    private func setupFocusTicker() {
        FocusManager.shared.onTick = { [weak self] title in
            guard let button = self?.statusItem.button else { return }
            if let title {
                button.title = " \(title)"
                button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "聚焦中")
            } else {
                button.title = ""
                button.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "TidyApp")
            }
        }
    }

    private func runSelfCheck() {
        Task { [weak self] in
            guard let self else { return }
            let results = await SelfCheck.run(env: self.env)
            self.selfCheckResults = results
            self.selfCheckMenuItem.title = SelfCheck.summaryLine(results)
            let failed = results.filter { !$0.ok }
            if !failed.isEmpty {
                ToastManager.shared.show("⚠️ 自检发现 \(failed.count) 项问题:\(failed.map(\.name).joined(separator: "、"))(状态栏菜单可查看)", duration: 6)
            }
        }
    }

    // MARK: - 动作

    @objc private func archiveFromFinder() {
        switch FinderSelection.fetch() {
        case .files(let files):
            ArchivePanelController.shared.present(files: files)
        case .permissionDenied:
            ToastManager.shared.show("⚠️ 需要「自动化」权限才能读取 Finder 选中项:系统设置 → 隐私与安全性 → 自动化 → Tidy → 勾选 Finder", duration: 9)
        case .scriptError(let msg):
            ToastManager.shared.show("⚠️ 读取 Finder 选中失败:\(msg)。也可以直接把文件拖到悬浮圆点", duration: 6)
        }
    }

    @objc private func showCapture() {
        let focusName = FocusManager.shared.isActive
            ? AppDatabase.shared.project(byId: FocusManager.shared.activeProjectId!)?.name : nil
        InputPanelController.shared.present(.init(
            title: "快速捕获",
            placeholder: "想法或链接,↵ 保存(理清可以稍后再说)…",
            contextChip: focusName.map { "将关联:\($0)" },
            icon: "lightbulb")) { text in
            // 文本里提到时间 → 自动打提醒标记
            let remind = DateMention.detect(in: text)
            var item = Item.newCapture(text: text,
                                       source: NSWorkspace.shared.frontmostApplication?.localizedName,
                                       remindAt: remind)
            try? AppDatabase.shared.dbQueue.write { db in try item.insert(db) }
            Telemetry.record(event: "capture", itemId: item.id,
                             chosenPath: remind != nil ? "with_remind" : nil)
            // 聚焦期间捕获默认关联当前项目(§4.2:显式上下文信号)
            if let itemId = item.id, let pid = FocusManager.shared.activeProjectId {
                try? AppDatabase.shared.dbQueue.write { db in
                    try ItemProjectLink(itemId: itemId, projectId: pid, relation: "primary", createdAt: Date()).insert(db)
                }
            }
            // 预理清(§4.5.6 prewarm):捕获后立即后台起草,打开理清面板时草稿秒出
            if let client = self.aiClient, let itemId = item.id {
                let projects = AppDatabase.shared.activeProjects()
                Task { @MainActor in
                    guard let draft = try? await client.clarify(
                        text: text, projectPaths: projects.map(\.path),
                        activeProjectPath: FocusManager.shared.activeProjectPath),
                          let json = try? JSONEncoder().encode(draft),
                          let str = String(data: json, encoding: .utf8) else { return }
                    try? await AppDatabase.shared.dbQueue.write { db in
                        try db.execute(sql: "UPDATE item SET summary = ? WHERE id = ? AND status = 'inbox'",
                                       arguments: [str, itemId])
                    }
                }
            }
            // GTD 两分钟规则:收集时就问,能 2 分钟解决就立即做
            var msg = focusName != nil ? "已捕获,关联「\(focusName!)」" : "已捕获"
            if let r = remind { msg += " · ⏰ \(DateMention.format(r)) 提醒" }
            msg += " · 2 分钟能搞定就现在做"
            ToastManager.shared.show(msg, actionTitle: "⚡ 做完了", duration: 6) {
                if let id = item.id {
                    AppDatabase.shared.markItemDone(id)
                    Telemetry.record(event: "two_min_done", itemId: id)
                    ToastManager.shared.show("⚡ 漂亮,两分钟规则 +1", duration: 2)
                }
            }
        }
    }

    @objc private func showWorkbench() { WorkbenchController.shared.toggle() }

    @objc private func undoLast() {
        if let msg = Archiver.shared.undoLast() {
            ToastManager.shared.show(msg, duration: 2.5)
        } else {
            ToastManager.shared.show("没有可撤销的归档", duration: 2)
        }
    }

    @objc private func startClarify() { ClarifyController.shared.startQueue() }
    @objc private func showReview() { ReviewPanelController.shared.present() }
    @objc private func showOnboarding() { OnboardingController.shared.present() }
    @objc private func endFocus() { FocusManager.shared.requestEnd() }
    @objc private func toggleDropWindow() { dropWindow.toggle() }

    @objc private func openInbox() {
        NSWorkspace.shared.open(ParaTree.root.appendingPathComponent("0-Inbox"))
    }

    @objc private func showStats() {
        WorkbenchController.shared.present(tab: .stats)
    }

    @objc private func showSelfCheck() {
        env = EnvConfig.load()  // 支持改完 .env 直接重跑
        let client = OpenAIClient(config: env)
        ArchivePanelController.shared.aiClient = client
        ClarifyController.shared.aiClient = client
        PlanController.shared.aiClient = client
        let current = selfCheckResults
        alert(title: "启动自检", text: current.isEmpty ? "运行中…" : SelfCheck.detailText(current))
        runSelfCheck()
    }

    @objc private func openEnvSettings() {
        EnvConfig.ensureTemplate()
        NSWorkspace.shared.open(EnvConfig.envFile)
        ToastManager.shared.show("填好保存后,点菜单里的「自检」即可重新加载配置", duration: 5)
    }

    @objc private func openMemoryFile() { NSWorkspace.shared.open(MemoryStore.memoryFile) }
    @objc private func openUserFile() { NSWorkspace.shared.open(MemoryStore.userFile) }
    @objc private func openPara() { NSWorkspace.shared.open(ParaTree.root) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
