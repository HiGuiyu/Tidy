import Foundation

/// 从自然语言里抽取时间提及(「周五下午3点跟张三对齐」→ 提醒标记)。
/// 本地 NSDataDetector,零成本零出网;AI 理清草稿的日期字段作为补充。
enum DateMention {
    static func detect(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        // 取第一个在未来的时间;纯日期(无时刻)默认当天 09:30 提醒
        for m in matches {
            guard var date = m.date else { continue }
            if m.timeIsSignificant == false {
                date = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: date) ?? date
            }
            if date > Date() { return date }
        }
        return nil
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(date) { f.dateFormat = "今天 HH:mm" }
        else if cal.isDateInTomorrow(date) { f.dateFormat = "明天 HH:mm" }
        else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day, days < 7 {
            f.dateFormat = "EEE HH:mm"
        } else {
            f.dateFormat = "M月d日 HH:mm"
        }
        return f.string(from: date)
    }
}

private extension NSTextCheckingResult {
    /// NSDataDetector 对「周五」这类只有日期的匹配,duration 为 0 且时间落在中午
    var timeIsSignificant: Bool {
        guard let d = date else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
        return !(comps.hour == 12 && comps.minute == 0 && duration == 0)
    }
}
