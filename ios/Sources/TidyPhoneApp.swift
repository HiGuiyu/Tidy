import SwiftUI

/// Tidy for iPhone:随手收进来,随时理清,只看下一步。
/// 四个顶层区(今天/收件箱/项目/清单),捕获是全局动作不占 Tab。
/// 本地优先:离线与无 AI 时核心流程完整可用;同步(CloudKit)属下一阶段。
@main
struct TidyPhoneApp: App {
    @StateObject private var store = PhoneStore()

    init() {
        // 基础设施:沙盒内 ~/.tidy(与 Mac 端同构:GRDB + MEMORY.md)
        MemoryStore.shared.ensureFiles()
        MemoryStore.shared.syncFromFiles()
        _ = AppDatabase.shared
        // 上次退出时残留在"两分钟即办"里的条目放回收件箱
        try? AppDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET status = 'inbox', gtdList = NULL WHERE gtdList = 'doing' AND id NOT IN (SELECT -1)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(PT.accent)
        }
    }
}

/// 全局数据快照:各页共用,单点刷新
@MainActor
final class PhoneStore: ObservableObject {
    @Published var inbox: [Item] = []
    @Published var nextActions: [Item] = []
    @Published var waiting: [Item] = []
    @Published var someday: [Item] = []
    @Published var doneRecent: [Item] = []
    @Published var projects: [Project] = []
    @Published var pausedProjects: [Project] = []
    @Published var projectNames: [Int64: String] = [:]
    @Published var doneToday = 0
    @Published var hint: SystemHint?

    init() { reload() }

    func reload() {
        let db = AppDatabase.shared
        inbox = db.inboxCaptures()
        nextActions = db.globalNextActions(limit: 30)
        waiting = db.items(inList: "waiting")
        someday = db.items(inList: "someday")
        doneRecent = db.doneItems(days: 7, limit: 50)
        projects = db.activeProjects()
        pausedProjects = (try? db.dbQueue.read { d in
            try Project.fetchAll(d, sql: "SELECT * FROM project WHERE status = 'paused' ORDER BY lastWorkedAt DESC NULLS LAST")
        }) ?? []
        let allIds = (inbox + nextActions + waiting + someday + doneRecent).compactMap(\.id)
        projectNames = db.projectNames(forItems: allIds).reduce(into: [:]) { $0[Int64($1.key)] = $1.value }
        doneToday = db.doneTodayCount()
        hint = SystemHint.top()
    }

    func nameOf(_ item: Item) -> String? {
        item.id.flatMap { projectNames[$0] }
    }

    func markDone(_ item: Item) {
        guard let id = item.id else { return }
        AppDatabase.shared.markItemDone(id)
        Telemetry.record(event: "done", itemId: id)
        if let next = AppDatabase.shared.unlockedStep(afterDone: item) {
            PhoneToast.shared.show("✓ 已完成 · 解锁下一步:\((next.nextAction ?? next.title).prefix(18))")
        } else {
            PhoneToast.shared.show("✓ 已完成", actionTitle: "撤销") { [weak self] in
                try? AppDatabase.shared.dbQueue.write { db in
                    try db.execute(sql: "UPDATE item SET status = 'clarified', completedAt = NULL WHERE id = ?",
                                   arguments: [id])
                }
                self?.reload()
            }
        }
        reload()
    }
}

struct RootView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var tab = 0
    @State private var showCapture = false
    @State private var clarifyQueue = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                TodayView(showCapture: $showCapture, startClarify: { clarifyQueue = true })
                    .tabItem { Label("今天", systemImage: "sun.max.fill") }
                    .tag(0)
                InboxView(startClarify: { clarifyQueue = true })
                    .tabItem {
                        Label("收件箱", systemImage: "tray.fill")
                    }
                    .badge(store.inbox.count)
                    .tag(1)
                ProjectsView()
                    .tabItem { Label("项目", systemImage: "folder.fill") }
                    .tag(2)
                ListsView()
                    .tabItem { Label("清单", systemImage: "checklist") }
                    .tag(3)
            }
            captureButton
            PhoneToastOverlay()
        }
        .sheet(isPresented: $showCapture) {
            CaptureSheet()
                .presentationDetents([.height(300), .medium])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $clarifyQueue) {
            ClarifyQueueView()
        }
        .onOpenURL { url in
            // tidy://capture / tidy://inbox 深链(组件与快捷指令预留)
            switch url.host {
            case "capture": showCapture = true
            case "inbox": tab = 1
            default: break
            }
        }
    }

    /// 全局快速捕获按钮(底部安全区上方,不占第五个 Tab)
    private var captureButton: some View {
        Button {
            showCapture = true
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(PT.accent.gradient))
                .shadow(color: PT.accent.opacity(0.4), radius: 10, y: 4)
        }
        .padding(.bottom, 58)
        .accessibilityLabel("快速捕获")
    }
}
