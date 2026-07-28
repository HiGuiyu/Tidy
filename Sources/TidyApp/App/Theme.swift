import SwiftUI

/// 统一设计系统(飞书风):一处定义,所有面板共用。
enum Theme {
    // 色板(参考飞书)
    static let accent = Color(red: 51/255, green: 112/255, blue: 255/255)   // #3370FF
    static let success = Color(red: 52/255, green: 199/255, blue: 89/255)   // 完成绿
    static let warning = Color(red: 255/255, green: 136/255, blue: 0)       // 提醒橙
    static let danger = Color(red: 245/255, green: 74/255, blue: 69/255)    // 逾期红
    static let violet = Color(red: 116/255, green: 79/255, blue: 254/255)   // AI 紫
    static let teal = Color(red: 20/255, green: 166/255, blue: 154/255)     // 等待青
    static let gray = Color.secondary

    static let radius: CGFloat = 12
    static let panelRadius: CGFloat = 16

    /// 主渐变:品牌蓝 → 紫,用于选中态/头部点缀
    static let gradient = LinearGradient(
        colors: [Color(red: 51/255, green: 112/255, blue: 255/255),
                 Color(red: 116/255, green: 79/255, blue: 254/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // 字号阶梯(加大一档,信息清晰可见)
    static let fontTitle = Font.system(size: 16, weight: .semibold)
    static let fontBody = Font.system(size: 14)
    static let fontSub = Font.system(size: 12.5)
    static let fontCaption = Font.system(size: 11.5)
    static let fontMicro = Font.system(size: 10.5)
}

/// 面板统一外壳:毛玻璃 + 圆角 + 细描边 + 入场动画(轻微放大浮现)
struct PanelChrome: ViewModifier {
    var width: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .frame(width: width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(.separator, lineWidth: 0.5))
            .tint(Theme.accent)
            .scaleEffect(shown ? 1 : 0.96)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(duration: 0.28, bounce: 0.25)) { shown = true }
            }
    }
}

extension View {
    func panelChrome(width: CGFloat) -> some View { modifier(PanelChrome(width: width)) }
}

/// 悬停感知容器:把 hovering 状态交给内容闭包,行/卡片的主动式交互都靠它
struct Hoverable<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovering)
            .onHover { h in
                withAnimation(.spring(duration: 0.22, bounce: 0.3)) { hovering = h }
            }
    }
}

/// 悬停上浮效果:卡片微放大 + 阴影,提示「可以点」
struct HoverLift: ViewModifier {
    @State private var hovering = false
    var scale: CGFloat = 1.03

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 8, y: 3)
            .onHover { h in
                withAnimation(.spring(duration: 0.22, bounce: 0.3)) { hovering = h }
            }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.03) -> some View { modifier(HoverLift(scale: scale)) }
}

/// 全局动作注册表:灵动岛/工作台等触发 App 级动作而不耦合 AppDelegate。
/// 菜单栏图标已移除,岛的右键菜单是这些动作的主入口。
@MainActor
enum AppActions {
    static var capture: () -> Void = {}
    static var archiveFinder: () -> Void = {}
    static var workbench: () -> Void = {}
    static var clarify: () -> Void = {}
    static var undo: () -> Void = {}
    static var endFocus: () -> Void = {}
    static var review: () -> Void = {}
    static var stats: () -> Void = {}
    static var onboarding: () -> Void = {}
    static var selfCheck: () -> Void = {}
    static var openMemory: () -> Void = {}
    static var openUser: () -> Void = {}
    static var openPara: () -> Void = {}
    static var openEnv: () -> Void = {}
    static var linkDocs: () -> Void = {}
    static var quit: () -> Void = {}
}

/// 头部图标徽章:彩色圆角小方块内嵌 SF Symbol(飞书式)
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(color.gradient))
    }
}

/// 小圆角标签
struct TagChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Theme.fontMicro)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }
}

/// 键位提示
struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            Text(label).font(Theme.fontCaption).foregroundStyle(.secondary)
        }
    }
}

/// GTD 四清单定义:名称、图标、颜色、适用说明(§需求:分别描述什么情况要用)
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
        case .action: return Theme.accent
        case .waiting: return Theme.teal
        case .someday: return Theme.gray
        }
    }

    /// 什么情况用这个清单
    var usage: String {
        switch self {
        case .action: return "下一步就能做的具体动作。所有项目的下一步都汇总在这里,完成前置步骤会自动解锁后置。"
        case .waiting: return "已委派他人或等外部条件(等回复/等审批/等到货)。记下等谁、等什么,跟进有据。"
        case .someday: return "现在不做、将来也许做的想法。每周复盘扫一眼,该激活就激活,该删就删。"
        }
    }
}
