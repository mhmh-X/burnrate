import Foundation

/// 一个限额窗口（5 小时窗或周窗）的用量。
struct WindowUsage {
    /// 已用百分比，0–100。
    let usedPercent: Double
    /// 窗口重置时间。
    let resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

/// 一个服务商（Claude / Codex）的整体用量。
struct ProviderUsage {
    let hourly: WindowUsage?
    let weekly: WindowUsage?
    let plan: String?
    /// 订阅到期时间（Codex 可从 id_token 拿到；Claude 接口不提供）。
    var planExpiresAt: Date? = nil
}

/// 中英双份的文案，渲染时才按当前语言取值，保证切换语言后已存在的错误也立即换语言。
struct BiText {
    let zh: String
    let en: String
    var text: String { L.isZH ? zh : en }
}

enum ProviderState {
    case loading
    case ok(ProviderUsage)
    case error(BiText)
}

protocol UsageProvider {
    var name: String { get }
    func fetch() async -> ProviderState
}

enum UsageError: Error {
    case message(String, String)   // (中文, English)

    var bi: BiText {
        if case .message(let zh, let en) = self { return BiText(zh: zh, en: en) }
        return BiText(zh: "未知错误", en: "Unknown error")
    }
}

extension Date {
    /// 距现在的剩余时长："3 天 4 小时" / "3d 4h"。
    var remainingDescription: String {
        remainingDescription(from: Date())
    }

    func remainingDescription(from now: Date) -> String {
        let total = Int(timeIntervalSince(now))
        guard total > 0 else { return L.t("即将", "soon") }
        let days = total / 86400
        let hours = total % 86400 / 3600
        let mins = total % 3600 / 60
        if L.isZH {
            if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天" }
            if hours > 0 { return mins > 0 ? "\(hours) 小时 \(mins) 分" : "\(hours) 小时" }
            return "\(max(mins, 1)) 分钟"
        } else {
            if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
            if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
            return "\(max(mins, 1))m"
        }
    }

    /// 简洁的重置时间描述："14:30"（今天）或 "周四 09:00" / "Thu 09:00"。
    var resetDescription: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: L.isZH ? "zh_CN" : "en_US")
        if Calendar.current.isDateInToday(self) {
            fmt.dateFormat = "HH:mm"
        } else if Calendar.current.isDateInTomorrow(self) {
            fmt.dateFormat = L.isZH ? "'明天' HH:mm" : "'tomorrow' HH:mm"
        } else {
            fmt.dateFormat = "EEE HH:mm"
        }
        return fmt.string(from: self)
    }

    /// 订阅到期日期："6月13日" / "Jun 13"。
    var expiryDescription: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: L.isZH ? "zh_CN" : "en_US")
        fmt.dateFormat = L.isZH ? "M月d日" : "MMM d"
        return fmt.string(from: self)
    }

    /// 时分："10:23" / "10:23 AM"，跟随应用语言而非系统 locale。
    var timeDescription: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: L.isZH ? "zh_CN" : "en_US")
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt.string(from: self)
    }
}
