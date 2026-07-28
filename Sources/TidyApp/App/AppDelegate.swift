import AppKit
import SwiftUI

/// 菜单栏图标已移除:灵动岛是唯一常驻入口(右键菜单承接全部功能),
/// 全局快捷键独立可用。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env = EnvConfig.load()
    private var aiClient: OpenAIClient?
    private var selfCheckResults: [SelfCheck.Result] = []

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

        registerActions()
        setupIsland()
        setupHotKeys()
        setupFocusTicker()
        runSelfCheck()
        OnboardingController.shared.showIfFirstLaunch()
    }

    // MARK: - 全局动作注册(灵动岛右键菜单 + 各面板共用)

    private func registerActions() {
        AppActions.capture = { [weak self] in self?.showCapture() }
        AppActions.archiveFinder = { [weak self] in self?.archiveFromFinder() }
        AppActions.workbench = { WorkbenchController.shared.toggle() }
        AppActions.clarify = { ClarifyController.shared.startQueue() }
        AppActions.undo = { [weak self] in self?.undoLast() }
        AppActions.endFocus = { FocusManager.shared.requestEnd() }
        AppActions.review = { ReviewPanelController.shared.present() }
        AppActions.stats = { WorkbenchController.shared.present(tab: .stats) }
        AppActions.onboarding = { OnboardingController.shared.present() }
        AppActions.selfCheck = { [weak self] in self?.showSelfCheck() }
        AppActions.openMemory = { NSWorkspace.shared.open(MemoryStore.memoryFile) }
        AppActions.openUser = { NSWorkspace.shared.open(MemoryStore.userFile) }
        AppActions.openPara = { NSWorkspace.shared.open(ParaTree.root) }
        AppActions.openEnv = { [weak self] in self?.openEnvSettings() }
        AppActions.quit = { NSApp.terminate(nil) }
    }

    // MARK: - 灵动岛 / 快捷键 / 聚焦

    private func setupIsland() {
        IslandController.shared.onDrop = { urls in
            ArchivePanelController.shared.present(files: urls)
        }
        IslandController.shared.show()
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
        FocusManager.shared.onTick = { title in
            IslandController.shared.setFocusText(title)
        }
    }

    private func runSelfCheck() {
        Task { [weak self] in
            guard let self else { return }
            let results = await SelfCheck.run(env: self.env)
            self.selfCheckResults = results
            let failed = results.filter { !$0.ok }
            if !failed.isEmpty {
                ToastManager.shared.show("⚠️ 自检发现 \(failed.count) 项问题:\(failed.map(\.name).joined(separator: "、"))(岛右键菜单 → 自检可查看)", duration: 7)
            }
        }
    }

    // MARK: - 动作实现

    private func archiveFromFinder() {
        switch FinderSelection.fetch() {
        case .files(let files):
            ArchivePanelController.shared.present(files: files)
        case .permissionDenied:
            ToastManager.shared.show("⚠️ 需要「自动化」权限才能读取 Finder 选中项:系统设置 → 隐私与安全性 → 自动化 → Tidy → 勾选 Finder", duration: 9)
        case .scriptError(let msg):
            ToastManager.shared.show("⚠️ 读取 Finder 选中失败:\(msg)。也可以直接把文件拖到灵动岛", duration: 6)
        }
    }

    private func showCapture() {
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
            // 预理清:捕获后立即后台起草;草稿就绪后岛上弹卡片,可直接采纳
            if let client = self.aiClient, let itemId = item.id {
                let projects = AppDatabase.shared.activeProjects()
                let captured = item
                Task { @MainActor in
                    guard let draft = try? await client.clarify(
                        text: text, projectPaths: projects.map(\.path),
                        activeProjectPath: FocusManager.shared.activeProjectPath),
                          let json = try? JSONEncoder().encode(draft),
                          let str = String(data: json, encoding: .utf8) else { return }
                    let stored: Bool = (try? await AppDatabase.shared.dbQueue.write { db in
                        try db.execute(sql: "UPDATE item SET summary = ? WHERE id = ? AND status = 'inbox'",
                                       arguments: [str, itemId])
                        return db.changesCount > 0
                    }) ?? false
                    guard stored else { return }
                    // 岛事件:AI 草稿就绪,一键采纳(vibeisland 式 agent 通知)
                    IslandController.shared.present(event: IslandEvent(
                        icon: "sparkles", color: Theme.violet,
                        title: draft.isActionable && !draft.nextAction.isEmpty
                            ? "AI 已理清 → \(draft.nextAction.prefix(24))"
                            : "AI 已理清:想法,建议\(draft.list == "someday" ? "搁置孵化" : "归档")",
                        subtitle: captured.title,
                        actions: [
                            IslandEvent.Action(label: "采纳", prominent: true) {
                                ClarifyController.adopt(itemId: itemId, draft: draft)
                                IslandController.shared.refresh()
                            },
                            IslandEvent.Action(label: "细看") {
                                if let it = try? AppDatabase.shared.dbQueue.read({ d in
                                    try Item.fetchOne(d, sql: "SELECT * FROM item WHERE id = ?", arguments: [itemId])
                                }) ?? nil {
                                    ClarifyController.shared.present(single: it)
                                }
                            },
                        ],
                        duration: 10, kind: "draft"))
                }
            }
            // GTD 两分钟规则:收集时就问
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

    private func undoLast() {
        if let msg = Archiver.shared.undoLast() {
            ToastManager.shared.show(msg, duration: 2.5)
            IslandController.shared.refresh()
        } else {
            ToastManager.shared.show("没有可撤销的归档", duration: 2)
        }
    }

    private func openEnvSettings() {
        EnvConfig.ensureTemplate()
        NSWorkspace.shared.open(EnvConfig.envFile)
        ToastManager.shared.show("填好保存后,岛右键 → 自检 即可重新加载配置", duration: 5)
    }

    private func showSelfCheck() {
        env = EnvConfig.load()  // 支持改完 .env 直接重跑
        let client = OpenAIClient(config: env)
        aiClient = client
        ArchivePanelController.shared.aiClient = client
        ClarifyController.shared.aiClient = client
        PlanController.shared.aiClient = client
        let current = selfCheckResults
        alert(title: "启动自检", text: current.isEmpty ? "运行中…" : SelfCheck.detailText(current))
        runSelfCheck()
    }

    private func alert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
