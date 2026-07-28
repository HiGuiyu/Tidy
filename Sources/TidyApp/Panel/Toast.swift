import AppKit
import SwiftUI

/// 右上角 toast(§10.3):3 秒自动消失,可带「撤销」按钮
@MainActor
final class ToastManager {
    static let shared = ToastManager()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, actionTitle: String? = nil, duration: TimeInterval = 3.5, action: (() -> Void)? = nil) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        // 消息自带 emoji 语气(⚠️/⏰/🎉…)时不再叠加绿色对勾
        let leadsWithEmoji = message.unicodeScalars.first.map {
            $0.properties.isEmojiPresentation || $0.value >= 0x1F000 || (0x2600...0x27BF).contains($0.value)
        } ?? false
        let view = ToastView(message: message, actionTitle: actionTitle, showsCheck: !leadsWithEmoji) { [weak self] in
            action?()
            self?.hide()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = (actionTitle == nil)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 12))
        }
        p.orderFrontRegardless()
        panel = p

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled { self?.hide() }
        }
    }

    func hide() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ToastView: View {
    let message: String
    let actionTitle: String?
    var showsCheck = true
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsCheck {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(message)
                .font(.system(size: 13))
                .lineLimit(2)
            if let title = actionTitle {
                Button(title, action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
