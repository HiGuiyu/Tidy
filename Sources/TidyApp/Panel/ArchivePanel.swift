import AppKit
import SwiftUI

/// 可成为 key window 的无边框面板(需要接收键盘输入)
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension NSWindow {
    /// 输入法处于组合态(拼音尚未上屏):此时回车=确认候选、数字=选字、方向键=翻页,
    /// 全部属于输入法,任何键盘监听都必须放行,否则会误触发面板操作
    var imeComposing: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}

/// 面板中的一行(建议 / 搜索结果 / 新建 / 收件箱)
struct PanelRow: Identifiable {
    enum Kind {
        case suggestion(Candidate)
        case search(Destination)
        case inbox
        case createProject(String)
        case createArea(String)
    }
    let kind: Kind
    let id: String
    let title: String
    let subtitle: String?
    let confidence: Double?
    let icon: String
}

/// 一次归档会话的全部状态
@MainActor
final class ArchiveSession: ObservableObject {
    let files: [URL]
    let openedAt = Date()
    let destinations: [Destination]
    let cold: Bool

    @Published var candidates: [Candidate] = []
    @Published var aiLoading = false
    @Published var aiNote: String? = nil
    @Published var searchText = "" { didSet { rebuildRows() } }
    @Published var selectedIndex = 0
    @Published var renameMode = false
    @Published var renameText = ""
    @Published var rows: [PanelRow] = []

    var usedCloud = false

    init(files: [URL], destinations: [Destination], cold: Bool) {
        self.files = files
        self.destinations = destinations
        self.cold = cold
        if let first = files.first {
            renameText = first.deletingPathExtension().lastPathComponent
        }
    }

    var headerTitle: String {
        guard let first = files.first else { return "" }
        return files.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) 等 \(files.count) 个文件"
    }

    func setCandidates(_ list: [Candidate], fromCloud: Bool) {
        candidates = list
        if fromCloud { usedCloud = true }
        rebuildRows()
    }

    func rebuildRows() {
        var result: [PanelRow] = []
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            for c in candidates.prefix(3) {
                result.append(PanelRow(kind: .suggestion(c), id: "s:\(c.relativePath)",
                                       title: c.relativePath,
                                       subtitle: c.reason.isEmpty ? nil : c.reason,
                                       confidence: c.confidence, icon: "folder"))
            }
            if result.isEmpty {
                result.append(PanelRow(kind: .inbox, id: "inbox",
                                       title: "0-Inbox(稍后再定)",
                                       subtitle: "先落地,不阻塞当前工作",
                                       confidence: nil, icon: "tray"))
            }
        } else {
            let scored = destinations
                .map { ($0, FuzzyMatcher.score(query: query, key: $0.searchKey)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(6)
            for (dest, _) in scored {
                result.append(PanelRow(kind: .search(dest), id: "d:\(dest.relativePath)",
                                       title: dest.relativePath, subtitle: nil,
                                       confidence: nil, icon: "folder"))
            }
            // 无精确同名目录时提供内联新建(§4.1:不匹配时无需跳出)
            let exact = destinations.contains { $0.leafName.lowercased() == query.lowercased() }
            if !exact {
                result.append(PanelRow(kind: .createProject(query), id: "np",
                                       title: "新建项目「\(query)」", subtitle: "创建 1-Projects/\(query) 并归档",
                                       confidence: nil, icon: "folder.badge.plus"))
                result.append(PanelRow(kind: .createArea(query), id: "na",
                                       title: "新建领域「\(query)」", subtitle: "创建 2-Areas/\(query) 并归档",
                                       confidence: nil, icon: "square.grid.2x2"))
            }
        }
        rows = result
        if selectedIndex >= rows.count { selectedIndex = max(0, rows.count - 1) }
        if !query.isEmpty { selectedIndex = min(selectedIndex, max(0, rows.count - 1)) }
    }
}

/// 确认面板控制器:唤起、键盘交互、执行归档、埋点与记忆回写
@MainActor
final class ArchivePanelController {
    static let shared = ArchivePanelController()

    private var panel: KeyablePanel?
    private var session: ArchiveSession?
    private var keyMonitor: Any?
    private var cloudTask: Task<Void, Never>?
    private var executing = false

    var aiClient: OpenAIClient?
    var activeProjectPathProvider: () -> String? = { nil }

    // MARK: - 唤起

    func present(files: [URL]) {
        guard !files.isEmpty else {
            ToastManager.shared.show("Finder 中没有选中的文件", duration: 2)
            return
        }
        close()  // 收掉旧面板

        let destinations = ParaTree.shared.freshDestinations()
        let cold = MemoryStore.shared.isCold()
        let s = ArchiveSession(files: files, destinations: destinations, cold: cold)
        session = s

        // 本地层即刻出结果(下限锁死:面板永远秒开)
        let activePath = activeProjectPathProvider()
        let local = Classifier.shared.localCandidates(fileName: files[0].lastPathComponent,
                                                      destinations: destinations,
                                                      activeProjectPath: activePath)
        s.setCandidates(local, fromCloud: false)
        Telemetry.record(event: "suggest",
                         suggestedPaths: local.map(\.relativePath),
                         suggestedScores: local.map(\.confidence),
                         usedCloud: false, modelTier: nil)
        if cold && local.isEmpty {
            s.aiNote = "记忆库冷启动中:这类文件你一般归到哪?直接搜索选择,你的选择会成为规则。"
        }

        showPanel(for: s)

        // 云端层按复杂度调档,结果到达且面板仍开着时合并(§4.5.7)
        if let client = aiClient, Classifier.shared.shouldCallCloud(localTop: local.first, cold: cold) {
            s.aiLoading = true
            cloudTask = Task { [weak self, weak s] in
                do {
                    let cloud = try await Classifier.shared.cloudCandidates(
                        fileURL: files[0], destinations: destinations,
                        activeProjectPath: activePath, client: client)
                    guard let self, let s, self.session === s, !Task.isCancelled else { return }
                    s.aiLoading = false
                    // 用户已开始搜索则不打扰
                    guard s.searchText.isEmpty else { return }
                    let merged = Classifier.shared.merge(local: local, cloud: cloud)
                    s.setCandidates(merged, fromCloud: true)
                    s.aiNote = nil
                    Telemetry.record(event: "suggest",
                                     suggestedPaths: merged.map(\.relativePath),
                                     suggestedScores: merged.map(\.confidence),
                                     usedCloud: true, modelTier: "light")
                } catch {
                    guard let s, !Task.isCancelled else { return }
                    s.aiLoading = false
                    s.aiNote = "AI 暂不可用(\((error as? OpenAIClient.AIError)?.errorDescription ?? error.localizedDescription))——手动搜索不受影响"
                }
            }
        }
    }

    private func showPanel(for s: ArchiveSession) {
        let view = ArchivePanelView(session: s,
                                    onExecute: { [weak self] row in self?.execute(row: row) },
                                    onCancel: { [weak self] in self?.cancel() })
        let hosting = NSHostingView(rootView: view)

        let width: CGFloat = 580
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 320),
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
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - width / 2, y: f.minY + f.height * 0.78))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow,
                  !panel.imeComposing else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// 键盘交互(§10.3):1/2/3 立即执行;↑↓ 选择;↵ 确认;打字即搜索;⇥ 重命名;esc 取消
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let s = session else { return false }
        switch event.keyCode {
        case 53: // esc
            if s.renameMode { s.renameMode = false; return true }
            if !s.searchText.isEmpty { s.searchText = ""; return true }
            cancel()
            return true
        case 36, 76: // return / keypad enter
            if s.rows.indices.contains(s.selectedIndex) {
                execute(row: s.rows[s.selectedIndex])
            }
            return true
        case 48: // tab:切换重命名(归档常伴随重命名)
            if s.files.count == 1 { s.renameMode.toggle() }
            return true
        case 126: // up
            s.selectedIndex = max(0, s.selectedIndex - 1)
            return true
        case 125: // down
            s.selectedIndex = min(max(0, s.rows.count - 1), s.selectedIndex + 1)
            return true
        default:
            // 搜索框为空时,数字 1-3 是最快路径:直接选中并立即执行;0 = 先扔进收件箱稍后再定
            if !s.renameMode, s.searchText.isEmpty,
               let ch = event.charactersIgnoringModifiers,
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if let n = Int(ch), (1...3).contains(n), s.rows.count >= n {
                    execute(row: s.rows[n - 1])
                    return true
                }
                if ch == "0" {
                    execute(row: PanelRow(kind: .inbox, id: "inbox",
                                          title: "0-Inbox(稍后再定)", subtitle: nil,
                                          confidence: nil, icon: "tray"))
                    return true
                }
            }
            return false // 其余按键交给输入框(打字即模糊搜索)
        }
    }

    // MARK: - 执行

    private func execute(row: PanelRow) {
        guard let s = session, !executing else { return }
        executing = true
        defer { executing = false }

        let dest: Destination
        switch row.kind {
        case .suggestion(let c):
            guard let d = s.destinations.first(where: { $0.relativePath == c.relativePath }) else { return }
            dest = d
        case .search(let d):
            dest = d
        case .inbox:
            dest = Destination(relativePath: "0-Inbox",
                               url: ParaTree.root.appendingPathComponent("0-Inbox"),
                               searchKey: SearchKey("0-Inbox"))
        case .createProject(let name):
            guard let d = try? ParaTree.shared.createDestination(kind: "project", name: name) else { return }
            dest = d
        case .createArea(let name):
            guard let d = try? ParaTree.shared.createDestination(kind: "area", name: name) else { return }
            dest = d
        }

        // 重命名:仅当用户进过重命名框且内容有变化
        var newName: String? = nil
        if s.renameMode || (s.files.count == 1 && s.renameText != s.files[0].deletingPathExtension().lastPathComponent) {
            newName = s.renameText
        }

        let latency = Int(Date().timeIntervalSince(s.openedAt) * 1000)
        let usedSearch = !s.searchText.isEmpty

        do {
            let results = try Archiver.shared.archive(files: s.files, to: dest, newBaseName: newName)
            recordOutcome(session: s, row: row, dest: dest, latency: latency, usedSearch: usedSearch, itemId: results.first?.itemId)
            close()
            IslandController.shared.refresh()
            ToastManager.shared.show("已归档到 \(dest.relativePath)", actionTitle: "撤销", duration: 5) {
                if let msg = Archiver.shared.undoLast() {
                    ToastManager.shared.show(msg, duration: 2.5)
                }
            }
        } catch {
            // 执行失败兜底:落 0-Inbox(§4.1),文件绝不丢
            let rescued = Archiver.shared.moveToInbox(files: s.files)
            close()
            if rescued.isEmpty {
                ToastManager.shared.show("归档失败:\(error.localizedDescription),文件留在原地", duration: 5)
            } else {
                ToastManager.shared.show("目标写入失败,已先放入 0-Inbox", actionTitle: "撤销") {
                    if let msg = Archiver.shared.undoLast() {
                        ToastManager.shared.show(msg, duration: 2.5)
                    }
                }
            }
        }
    }

    /// 埋点 + 记忆回写:修正 100% 被记录(P0 验收)
    private func recordOutcome(session s: ArchiveSession, row: PanelRow, dest: Destination,
                               latency: Int, usedSearch: Bool, itemId: Int64?) {
        var rank: Int? = nil
        if case .suggestion = row.kind,
           let idx = s.rows.firstIndex(where: { $0.id == row.id }), !usedSearch {
            rank = idx + 1
        }
        let event = (rank == 1) ? "confirm" : "correct"
        Telemetry.record(event: event, itemId: itemId,
                         suggestedPaths: s.candidates.map(\.relativePath),
                         suggestedScores: s.candidates.map(\.confidence),
                         chosenPath: dest.relativePath, chosenRank: rank,
                         latencyMs: latency, usedCloud: s.usedCloud,
                         modelTier: s.usedCloud ? "light" : nil)
        if usedSearch {
            Telemetry.record(event: "fallbackSearch", itemId: itemId, chosenPath: dest.relativePath, latencyMs: latency)
        }

        let fileName = s.files[0].lastPathComponent
        let how = rank.map { "建议第 \($0) 位" } ?? "手动搜索"
        MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 归档 \(fileName) → \(dest.relativePath)(\(how))")

        // 修正(未选第 1 位)是最强学习信号:落种子语义规则(§4.5.5 冷启动即日常)
        if rank != 1, let token = salientToken(of: fileName) {
            MemoryStore.shared.recordSemanticRule("含「\(token)」的文件 → \(dest.relativePath)")
        }
        // trust scoring:采纳的候选背后的记忆 hit+1,首位被否的 miss+1
        let hitIds = s.candidates.first(where: { $0.relativePath == dest.relativePath })?.memoryIds ?? []
        let missIds = (rank == 1) ? [] : (s.candidates.first?.memoryIds ?? [])
        MemoryStore.shared.feedback(hit: hitIds, miss: missIds.filter { !hitIds.contains($0) })
    }

    /// 提取文件名中最有辨识度的词(最长 CJK 串,否则最长英文词)
    private func salientToken(of fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        var cjkRuns: [String] = [], asciiRuns: [String] = []
        var cjk = "", ascii = ""
        for ch in base {
            let isCJK = ch.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false
            if isCJK { cjk.append(ch); if !ascii.isEmpty { asciiRuns.append(ascii); ascii = "" } }
            else if ch.isLetter { ascii.append(ch); if !cjk.isEmpty { cjkRuns.append(cjk); cjk = "" } }
            else {
                if !cjk.isEmpty { cjkRuns.append(cjk); cjk = "" }
                if !ascii.isEmpty { asciiRuns.append(ascii); ascii = "" }
            }
        }
        if !cjk.isEmpty { cjkRuns.append(cjk) }
        if !ascii.isEmpty { asciiRuns.append(ascii) }
        if let best = cjkRuns.filter({ $0.count >= 2 }).max(by: { $0.count < $1.count }) { return best }
        if let best = asciiRuns.filter({ $0.count >= 3 }).max(by: { $0.count < $1.count }) { return best.lowercased() }
        return nil
    }

    private func cancel() {
        // esc:文件留在原地,不产生任何待办(§4.1)
        close()
    }

    func close() {
        cloudTask?.cancel()
        cloudTask = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        session = nil
    }
}

// MARK: - SwiftUI 视图

struct ArchivePanelView: View {
    @ObservedObject var session: ArchiveSession
    let onExecute: (PanelRow) -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Field?

    enum Field { case search, rename }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            if let note = session.aiNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            rowsList
            Divider().padding(.horizontal, 14)
            searchArea
            footer
        }
        .panelChrome(width: 580)
        .onAppear {
            focus = .search
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focus = .search }
        }
        .onChange(of: session.renameMode) { _, renaming in
            focus = renaming ? .rename : .search
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: session.files[0].path))
                .resizable().frame(width: 22, height: 22)
            Text(session.headerTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if session.aiLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("AI 分析中").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var rowsList: some View {
        VStack(spacing: 2) {
            if session.rows.isEmpty {
                Text(session.searchText.isEmpty ? "输入关键字搜索归档位置" : "无匹配位置——继续输入或新建")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            }
            ForEach(Array(session.rows.enumerated()), id: \.element.id) { idx, row in
                rowView(row, index: idx)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func rowView(_ row: PanelRow, index: Int) -> some View {
        let selected = index == session.selectedIndex
        return HStack(spacing: 10) {
            Text(index < 3 && session.searchText.isEmpty ? "\(index + 1)" : "·")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(selected ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.15)))
            Image(systemName: row.icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1).truncationMode(.middle)
                if let sub = row.subtitle {
                    Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let conf = row.confidence {
                Text("\(Int(conf * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(conf >= 0.7 ? Color.green : Color.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { onExecute(row) }
        .onHover { if $0 { session.selectedIndex = index } }
    }

    private var searchArea: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("输入任意字符搜索其他位置(支持拼音首字母,如 khj)…", text: $session.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focus, equals: .search)
            }
            if session.renameMode {
                HStack(spacing: 8) {
                    Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(.orange)
                    TextField("新文件名(不含扩展名)", text: $session.renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focus, equals: .rename)
                    Text(".\(session.files[0].pathExtension)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("1-3", "立即归档")
            hint("0", "先进收件箱")
            hint("↑↓", "选择")
            hint("↵", "归档")
            if session.files.count == 1 { hint("⇥", session.renameMode ? "取消重命名" : "重命名") }
            hint("esc", "取消")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}
