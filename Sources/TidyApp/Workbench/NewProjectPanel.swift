import AppKit
import SwiftUI

/// 应用内新建项目/领域(不用去 Finder 建文件夹)。
/// 确认即完成三件事:创建 PARA 目录 + 建库记录 + 绑定(path 为纽带)。
@MainActor
final class NewProjectController {
    static let shared = NewProjectController()

    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var model: NewProjectModel?
    private var onCreated: ((Project?) -> Void)?

    func present(defaultName: String = "", onCreated: ((Project?) -> Void)? = nil) {
        close()
        self.onCreated = onCreated
        let m = NewProjectModel()
        m.name = defaultName
        model = m

        let view = NewProjectView(model: m,
                                  onConfirm: { [weak self] in self?.confirm() },
                                  onCancel: { [weak self] in self?.close() })
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
                                           y: f.minY + f.height * 0.8))
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 53: self.close(); return nil
            case 36, 76: self.confirm(); return nil
            default: return event
            }
        }
    }

    private func confirm() {
        guard let m = model else { return }
        let name = m.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            m.errorText = "名称不能为空"
            return
        }
        let top = m.isArea ? "2-Areas" : "1-Projects"
        if ParaTree.shared.freshDestinations().contains(where: { $0.relativePath == "\(top)/\(name)" }) {
            m.errorText = "「\(name)」已存在"
            return
        }
        do {
            let dest = try ParaTree.shared.createDestination(kind: m.isArea ? "area" : "project", name: name)
            var created: Project? = nil
            if !m.isArea, let proj = AppDatabase.shared.project(byPath: dest.relativePath), let pid = proj.id {
                AppDatabase.shared.updateProjectMeta(pid, due: m.hasDue ? m.due : nil,
                                                     purpose: m.purpose.trimmingCharacters(in: .whitespaces))
                created = AppDatabase.shared.project(byId: pid)
            }
            Telemetry.record(event: m.isArea ? "area_created" : "project_created", chosenPath: dest.relativePath)
            MemoryStore.shared.recordEpisodic("\(Archiver.dateStr()) 新建\(m.isArea ? "领域" : "项目")「\(name)」")
            let cb = onCreated
            close()
            ToastManager.shared.show("✓ 已创建 \(dest.relativePath),目录与项目已绑定", duration: 3)
            cb?(created)
        } catch {
            m.errorText = "创建失败:\(error.localizedDescription)"
        }
    }

    func close() {
        if let mo = keyMonitor { NSEvent.removeMonitor(mo); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        model = nil
        onCreated = nil
    }
}

@MainActor
final class NewProjectModel: ObservableObject {
    @Published var name = ""
    @Published var isArea = false
    @Published var hasDue = false
    @Published var due = Calendar.current.date(byAdding: .day, value: 14, to: Date())!
    @Published var purpose = ""
    @Published var errorText: String? = nil
}

private struct NewProjectView: View {
    @ObservedObject var model: NewProjectModel
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconBadge(systemName: "folder.badge.plus", color: Theme.teal)
                Text("新建\(model.isArea ? "领域" : "项目")").font(Theme.fontTitle)
                Spacer()
                Picker("", selection: $model.isArea) {
                    Text("项目 · 有终点").tag(false)
                    Text("领域 · 持续维护").tag(true)
                }
                .pickerStyle(.segmented).controlSize(.small).frame(width: 220)
            }
            TextField(model.isArea ? "领域名称,如:健康 / 财务 / 团队管理"
                                   : "项目名称,如:公司-客户A支付网关", text: $model.name)
                .textFieldStyle(.roundedBorder).font(Theme.fontBody)
                .focused($nameFocused)
            if !model.isArea {
                HStack(spacing: 10) {
                    Toggle("截止日期", isOn: $model.hasDue)
                        .toggleStyle(.checkbox).font(Theme.fontSub)
                    if model.hasDue {
                        DatePicker("", selection: $model.due, displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden().controlSize(.small)
                    }
                    Spacer()
                }
                TextField("一句话目的(可选,会帮 AI 更准地关联归档与理清)", text: $model.purpose)
                    .textFieldStyle(.roundedBorder).font(Theme.fontSub)
            }
            Text("确认后自动创建 \(model.isArea ? "2-Areas" : "1-Projects")/\(model.name.isEmpty ? "…" : model.name) 目录并绑定")
                .font(Theme.fontMicro).foregroundStyle(.tertiary)
            if let err = model.errorText {
                Text(err).font(Theme.fontCaption).foregroundStyle(Theme.danger)
            }
            HStack {
                Text("esc 取消").font(Theme.fontCaption).foregroundStyle(.tertiary)
                Spacer()
                Button("取消", action: onCancel).controlSize(.small)
                Button(action: onConfirm) { Label("创建 ↵", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .panelChrome(width: 480)
        .onAppear { nameFocused = true }
    }
}
