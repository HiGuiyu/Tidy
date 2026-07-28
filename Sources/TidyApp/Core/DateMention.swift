import Foundation

/// 从自然语言里抽取时间提及(「周五下午3点跟张三对齐」→ 提醒标记)。
/// 两级识别:NSDataDetector(西文及 zh locale 下的中文)→ 中文正则兜底(不依赖系统语言,
/// 保证英文系统的用户写中文时间同样可用;也是 CI 可测的路径)。
enum DateMention {
    static func detect(in text: String) -> Date? {
        if let d = detectSystem(text) { return d }
        return detectChinese(text)
    }

    // MARK: - 系统检测器

    private static func detectSystem(_ text: String) -> Date? {
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

    // MARK: - 中文口语解析(locale 无关)

    /// 支持:今天/明天/后天/大后天、周X/星期X/下周X、X月X日,
    /// 搭配 凌晨/早上/上午/中午/下午/晚上 X点[半|X分]。仅有日期时默认 09:30。
    static func detectChinese(_ text: String, now: Date = Date()) -> Date? {
        let cal = Calendar.current

        // ―― 哪一天 ――
        var dayOffset: Int? = nil
        if text.contains("大后天") { dayOffset = 3 }
        else if text.contains("后天") { dayOffset = 2 }
        else if text.contains("明天") || text.contains("明早") || text.contains("明晚") || text.contains("明日") { dayOffset = 1 }
        else if text.contains("今天") || text.contains("今晚") || text.contains("今早") { dayOffset = 0 }

        var weekday: Int? = nil   // Calendar: 1=周日 … 7=周六
        var nextWeek = false
        if let m = match("(下{1,2})?(?:周|星期|礼拜)([一二三四五六日天])", text) {
            nextWeek = (m[1]?.isEmpty == false)
            let map: [String: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4,
                                      "四": 5, "五": 6, "六": 7]
            weekday = m[2].flatMap { map[$0] }
        }

        var month: Int? = nil, dayOfMonth: Int? = nil
        if let m = match("(\\d{1,2})月(\\d{1,2})[日号]", text) {
            month = m[1].flatMap(Int.init)
            dayOfMonth = m[2].flatMap(Int.init)
        }

        // ―― 几点 ――
        var hour: Int? = nil
        var minute = 0
        if let m = match("(凌晨|清晨|早上|上午|中午|下午|晚上|傍晚|今晚|明晚)?\\s*(\\d{1,2})\\s*[点时:](半|\\d{1,2})?", text),
           let h = m[2].flatMap(Int.init), h <= 24 {
            hour = h
            if let tail = m[3] {
                if tail == "半" { minute = 30 } else { minute = min(Int(tail) ?? 0, 59) }
            }
            switch m[1] {
            case "下午", "晚上", "傍晚", "今晚", "明晚":
                if h < 12 { hour = h + 12 }
            case "中午":
                hour = h == 12 || h < 3 ? h + (h < 3 ? 12 : 0) : 12
            case "凌晨":
                if h == 12 { hour = 0 }
            default: break
            }
        }

        // 什么线索都没有 → 不是时间提及
        guard dayOffset != nil || weekday != nil || month != nil || hour != nil else { return nil }

        // ―― 组装 ――
        var base = cal.startOfDay(for: now)
        if let off = dayOffset {
            base = cal.date(byAdding: .day, value: off, to: base) ?? base
        } else if let wd = weekday {
            let todayWd = cal.component(.weekday, from: now)
            var days = (wd - todayWd + 7) % 7
            if nextWeek {
                // 下周X = 下个周一再偏移到目标
                let toNextMonday = ((2 - todayWd + 7) % 7 == 0) ? 7 : (2 - todayWd + 7) % 7
                days = toNextMonday + (wd - 2 + 7) % 7
            } else if days == 0 {
                days = 7   // 「周三」在周三当天说,视为下周三(当天会用具体钟点表达)
            }
            base = cal.date(byAdding: .day, value: days, to: base) ?? base
        } else if let mo = month, let d = dayOfMonth {
            var comps = cal.dateComponents([.year], from: now)
            comps.month = mo
            comps.day = d
            guard var dt = cal.date(from: comps) else { return nil }
            if dt < cal.startOfDay(for: now) {
                dt = cal.date(byAdding: .year, value: 1, to: dt) ?? dt
            }
            base = dt
        }

        var result = cal.date(bySettingHour: hour ?? 9, minute: hour == nil ? 30 : minute,
                              second: 0, of: base) ?? base
        // 只说了钟点没说哪天,且已过 → 顺延到明天
        if dayOffset == nil, weekday == nil, month == nil, result <= now {
            result = cal.date(byAdding: .day, value: 1, to: result) ?? result
        }
        return result > now ? result : nil
    }

    /// 正则匹配,返回捕获组(nil = 该组未命中)
    private static func match(_ pattern: String, _ text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
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
