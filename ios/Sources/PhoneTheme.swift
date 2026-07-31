import SwiftUI

/// iPhone 端主题:继承 Mac 端语义色,系统背景/材质/SF Symbols 为主,品牌色只做强调。
enum PT {
    static let accent = Color(red: 51/255, green: 112/255, blue: 255/255)
    static let success = Color(red: 52/255, green: 199/255, blue: 89/255)
    static let warning = Color(red: 255/255, green: 136/255, blue: 0)
    static let danger = Color(red: 245/255, green: 74/255, blue: 69/255)
    static let violet = Color(red: 116/255, green: 79/255, blue: 254/255)
    static let teal = Color(red: 20/255, green: 166/255, blue: 154/255)
}

/// GTD 清单(与 Mac 端语义一致)
enum GTDList: String, CaseIterable, Identifiable {
    case action, waiting, someday

    var id: String { rawValue }

    var name: String {
        switch self {
        case .action: return "行动"
        case .waiting: return "等待"
        case .someday: return "搁置"
        }
    }

    var icon: String {
        switch self {
        case .action: return "bolt.fill"
        case .waiting: return "hourglass"
        case .someday: return "moon.zzz.fill"
        }
    }

    var color: Color {
        switch self {
        case .action: return PT.accent
        case .waiting: return PT.teal
        case .someday: return .gray
        }
    }

    var usage: String {
        switch self {
        case .action: return "下一步就能做的具体动作,所有项目汇总在这里"
        case .waiting: return "已委派或等外部条件,记下等谁、等什么"
        case .someday: return "现在不做、将来也许,回顾时扫一眼"
        }
    }
}

/// 项目名 → 稳定专属色(与 Mac 端同算法,两端视觉一致)
func projectTint(_ name: String) -> Color {
    var h: UInt32 = 5381
    for u in name.unicodeScalars { h = h &* 33 &+ u.value }
    return Color(hue: Double(h % 330) / 360.0, saturation: 0.55, brightness: 0.92)
}

struct PTChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// 轻量应用内反馈(捕获成功、撤销等;不发系统通知)
@MainActor
final class PhoneToast: ObservableObject {
    static let shared = PhoneToast()

    struct Msg: Identifiable {
        let id = UUID()
        var text: String
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
    }

    @Published var current: Msg?
    private var task: Task<Void, Never>?

    func show(_ text: String, actionTitle: String? = nil,
              duration: TimeInterval = 3, action: (() -> Void)? = nil) {
        task?.cancel()
        withAnimation(.spring(duration: 0.3)) {
            current = Msg(text: text, actionTitle: actionTitle, action: action)
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation { self?.current = nil }
            }
        }
    }

    func hide() {
        task?.cancel()
        withAnimation { current = nil }
    }
}

struct PhoneToastOverlay: View {
    @ObservedObject var toast = PhoneToast.shared

    var body: some View {
        VStack {
            Spacer()
            if let m = toast.current {
                HStack(spacing: 10) {
                    Text(m.text).font(.footnote).lineLimit(2)
                    if let t = m.actionTitle {
                        Button(t) {
                            m.action?()
                            toast.hide()
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .padding(.bottom, 84)   // 悬于捕获按钮之上
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(toast.current != nil)
    }
}
