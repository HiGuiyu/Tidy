import SwiftUI

/// 快速捕获(半屏):先收下,后判断。
/// 保存顺序:本地写入成功 → 反馈成功 → 异步生成草稿。
struct CaptureSheet: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var text = ""
    @State private var savedItem: Item?
    @State private var detectedRemind: Date?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let saved = savedItem {
                    savedState(saved)
                } else {
                    inputState
                }
                Spacer()
            }
            .padding()
            .navigationTitle("快速捕获")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: 输入态

    private var inputState: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("想法或链接,先收下再说…", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .font(.body)
                .focused($focused)
                .onAppear { focused = true }
                .onChange(of: text) { _, t in
                    detectedRemind = DateMention.detect(in: t)
                }
                .onSubmit { save() }
            HStack(spacing: 8) {
                if let name = PhoneFocus.shared.projectName {
                    PTChip(text: "将关联:\(name)", color: PT.accent)
                }
                if let r = detectedRemind {
                    PTChip(text: "⏰ \(DateMention.format(r))", color: PT.warning)
                }
                Spacer()
            }
            Button {
                save()
            } label: {
                Label("收进 Inbox", systemImage: "tray.and.arrow.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var item = Item.newCapture(text: t, source: "iPhone", remindAt: detectedRemind)
        try? AppDatabase.shared.dbQueue.write { db in try item.insert(db) }
        Telemetry.record(event: "capture", itemId: item.id,
                         chosenPath: detectedRemind != nil ? "with_remind" : nil)
        // 聚焦期间捕获默认关联当前项目
        if let itemId = item.id, let pid = PhoneFocus.shared.projectId {
            try? AppDatabase.shared.dbQueue.write { db in
                try ItemProjectLink(itemId: itemId, projectId: pid, relation: "primary", createdAt: Date()).insert(db)
            }
        }
        savedItem = item
        // 本地成功后才异步起草(失败只影响草稿)
        if let id = item.id { DraftBox.prewarm(itemId: id, text: t) }
        store.reload()
    }

    // MARK: 已保存态:两分钟规则 + 继续添加

    private func savedState(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("已收进 Inbox", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(PT.success)
            Text(item.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let r = item.remindAt {
                PTChip(text: "⏰ \(DateMention.format(r)) 提醒", color: PT.warning)
            }
            HStack(spacing: 10) {
                Button {
                    if let id = item.id {
                        PhoneTwoMin.shared.start(itemId: id, title: item.title)
                        store.reload()
                    }
                    dismiss()
                } label: {
                    Label("马上做(2 分钟)", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(PT.warning)
                Button {
                    savedItem = nil
                    text = ""
                    detectedRemind = nil
                    focused = true
                } label: {
                    Label("继续添加", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            Button("完成") { dismiss() }
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
        }
    }
}
