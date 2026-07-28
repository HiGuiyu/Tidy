import SwiftUI

/// 可点击的提醒标签:有提醒显示 ⏰ 时间(逾期变红),点击弹日历修改/清除;
/// 无提醒时按需显示「＋提醒」。全部清单行、理清面板、项目详情共用。
struct RemindChipEditor: View {
    let remindAt: Date?
    var showPlusWhenEmpty = false
    let onSet: (Date?) -> Void

    @State private var showPopover = false
    @State private var draft = Date()

    var body: some View {
        Group {
            if let r = remindAt {
                Button {
                    draft = r
                    showPopover = true
                } label: {
                    TagChip(text: "⏰ \(DateMention.format(r))",
                            color: r < Date() ? Theme.danger : Theme.warning)
                }
                .buttonStyle(.plain)
                .help("点击修改/清除提醒")
            } else if showPlusWhenEmpty {
                Button {
                    draft = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0,
                                                  of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!) ?? Date()
                    showPopover = true
                } label: {
                    TagChip(text: "＋提醒", color: .secondary)
                }
                .buttonStyle(.plain)
                .help("给这条待办加时间提醒")
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                DatePicker("", selection: $draft, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 240)
                HStack {
                    if remindAt != nil {
                        Button("清除提醒") {
                            onSet(nil)
                            showPopover = false
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    Button("保存") {
                        onSet(draft)
                        showPopover = false
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(12)
        }
    }
}
