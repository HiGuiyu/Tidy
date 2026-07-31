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
        FocusManager.shared.checkRecovery()   // 上次聚焦未正常结束 → 询问
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
        AppActions.linkDocs = { Self.linkFinderSelection() }
        AppActions.quit = { NSApp.terminate(nil) }

        // 恢复:上次退出时还在"两分钟即办"里的条目放回收件箱,不留 limbo
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET status = 'inbox', gtdList = NULL WHERE gtdList = 'doing'")
        }
    }

    // MARK: - 灵动岛 / 快捷键 / 聚焦

    private func setupIsland() {
        IslandController.shared.onDrop = { urls in
            ArchivePanelController.shared.present(files: urls)
        }
        IslandController.shared.show()
    }

    private func setupHotKeys() {
        // 双击 ⌘ = 捕获(零记忆成本的第一入口;全局生效需辅助功能权限)
        DoubleTapCommand.shared.onDoubleTap = { [weak self] in self?.showCapture() }
        DoubleTapCommand.shared.start()
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
                    // 两分钟即办进行中:这条不进后续流程,不弹草稿卡(草稿留库备用)
                    guard !TwoMinuteTimer.shared.isRunning(for: itemId) else { return }
                    // 岛事件:AI 草稿就绪。低置信时不给"采纳",只呈现那一个关键问题
                    let projLeaf = draft.projectPath.components(separatedBy: "/").last
                    let lookAction = IslandEvent.Action(label: draft.isLowConfidence ? "回答并理清" : "细看",
                                                        prominent: draft.isLowConfidence) {
                        if let it = try? AppDatabase.shared.dbQueue.read({ d in
                            try Item.fetchOne(d, sql: "SELECT * FROM item WHERE id = ?", arguments: [itemId])
                        }) ?? nil {
                            ClarifyController.shared.present(single: it)
                        }
                    }
                    if draft.isLowConfidence {
                        IslandController.shared.present(event: IslandEvent(
                            icon: "questionmark.circle.fill", color: Theme.violet,
                            title: draft.question?.isEmpty == false
                                ? "AI 想确认:\(draft.question!.prefix(30))"
                                : "AI 拿不准这条怎么分流",
                            subtitle: captured.title,
                            actions: [lookAction],
                            duration: 10, kind: "draft"))
                    } else {
                        let draftTitle: String
                        if draft.isActionable && !draft.nextAction.isEmpty {
                            draftTitle = projLeaf.map { "「\($0)」\(draft.nextAction.prefix(22))" }
                                ?? "AI 已理清 → \(draft.nextAction.prefix(24))"
                        } else {
                            draftTitle = "AI 已理清:想法,建议\(draft.list == "someday" ? "搁置孵化" : "归档")"
                        }
                        IslandController.shared.present(event: IslandEvent(
                            icon: "sparkles", color: Theme.violet,
                            title: draftTitle,
                            subtitle: captured.title,
                            actions: [
                                IslandEvent.Action(label: "采纳", prominent: true) {
                                    ClarifyController.adopt(itemId: itemId, draft: draft)
                                    IslandController.shared.refresh()
                                },
                                lookAction,
                            ],
                            duration: 10, kind: "draft"))
                    }
                }
            }
            // GTD 两分钟规则:点「马上做」即开 2:00 倒计时,岛上像素闪动陪跑
            var msg = focusName != nil ? "已捕获,关联「\(focusName!)」" : "已捕获"
            if let r = remind { msg += " · ⏰ \(DateMention.format(r)) 提醒" }
            msg += " · 2 分钟能搞定?"
            let captureTitle = item.title
            ToastManager.shared.show(msg, actionTitle: "⚡ 马上做", duration: 6) {
                if let id = item.id {
                    TwoMinuteTimer.shared.start(itemId: id, title: captureTitle)
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

    /// 文档关联 v1:Finder 选中 ≥2 个文件 → 两两建立关系
    private static func linkFinderSelection() {
        switch FinderSelection.fetch() {
        case .files(let urls) where urls.count >= 2:
            let added = AppDatabase.shared.linkDocs(urls.map(\.path))
            let names = urls.prefix(2).map { $0.lastPathComponent }.joined(separator: "、")
            MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 关联文档:\(names) 等 \(urls.count) 个")
            ToastManager.shared.show("🔗 已关联 \(urls.count) 个文档(新增 \(added) 组关系),工作台文件行可见", duration: 4)
        case .files:
            ToastManager.shared.show("🔗 请在 Finder 同时选中 2 个以上文档,再点「关联」", duration: 4)
        case .permissionDenied:
            ToastManager.shared.show("⚠️ 需要「自动化」权限:系统设置 → 隐私与安全性 → 自动化 → Tidy → Finder", duration: 8)
        case .scriptError(let msg):
            ToastManager.shared.show("⚠️ 读取选中失败:\(msg)", duration: 5)
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
