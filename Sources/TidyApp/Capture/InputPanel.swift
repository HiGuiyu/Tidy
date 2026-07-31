import AppKit
import SwiftUI

/// 通用单行输入面板:快速捕获(⌥⌘N)与聚焦结束进展记录共用。
/// Spotlight 式浮层,↵ 提交,esc 取消。
@MainActor
final class InputPanelController {
    static let shared = InputPanelController()

    private var panel: KeyablePanel?
    private var keyMonitor: Any?

    struct Config {
        var title: String
        var placeholder: String
        var contextChip: String?     // 如「将关联:客户A支付网关」
        var icon: String = "lightbulb"
        var allowEmpty = false       // 允许空提交(如聚焦结束时直接 ↵ 跳过记录)
    }

    private var cancelHandler: (() -> Void)?

    func present(_ config: Config, onSubmit: @escaping (String) -> Void,
                 onCancel: (() -> Void)? = nil) {
        close()
        cancelHandler = onCancel
        let model = InputModel()
        let view = InputPanelView(config: config, model: model,
                                  onSubmit: { [weak self] text in
                                      self?.cancelHandler = nil
                                      self?.close()
                                      let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                      if !t.isEmpty { onSubmit(t) }
                                      else if config.allowEmpty { onSubmit("") }
                                  },
                                  onCancel: { [weak self] in self?.cancel() })
        let hosting = NSHostingView(rootView: view)
        let width: CGFloat = 560
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
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
        // 先激活应用再置 key,否则非激活状态下 TextField 拿不到光标
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow,
                  !panel.imeComposing else { return event }
            if event.keyCode == 53 { self.cancel(); return nil }  // esc
            return event
        }
    }

    private func cancel() {
        let handler = cancelHandler
        cancelHandler = nil
        close()
        handler?()
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
final class InputModel: ObservableObject {
    @Published var text = ""
}

private struct InputPanelView: View {
    let config: InputPanelController.Config
    @ObservedObject var model: InputModel
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconBadge(systemName: config.icon, color: Theme.accent)
                Text(config.title).font(Theme.fontTitle)
                Spacer()
                if let chip = config.contextChip {
                    TagChip(text: chip, color: Theme.accent)
                }
            }
            TextField(config.placeholder, text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { onSubmit(model.text) }
            HStack(spacing: 14) {
                Text("↵ 保存").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text("esc 取消").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .panelChrome(width: 560)
        .onAppear {
            // 立即 + 延迟双重置焦:面板激活时序偶发吞掉第一次 FocusState
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
        }
    }
}
