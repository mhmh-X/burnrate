import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var claude: ProviderState = .loading
    @Published var codex: ProviderState = .loading
    /// 刷新失败但仍在展示旧数据时的提示。
    @Published var claudeNote: BiText?
    @Published var codexNote: BiText?
    /// 最近一次刷新尝试时间（成功与否都更新），用于"打开菜单时是否需要刷新"的判断。
    @Published var lastUpdated: Date?
    /// 各服务商最近一次成功获取的时间；失败不更新，避免展示陈旧时间。
    @Published var claudeUpdated: Date?
    @Published var codexUpdated: Date?
    @Published var refreshing = false
    /// 当前界面语言（"zh" / "en"），改变时触发整个 UI 重渲染。
    @Published var languageCode: String = L.code
    /// Claude Code 任务状态（启动时自动尝试安装 hook，失败则保持 none）。
    @Published var taskStatus: TaskStatus.State = .none
    /// Codex 任务状态（通过本机会话文件末尾事件 best-effort 获取）。
    @Published var codexTaskStatus: TaskStatus.State = .none

    func setLanguage(_ code: String) {
        L.set(code)
        languageCode = code
    }

    private let claudeProvider = ClaudeProvider()
    private let codexProvider = CodexProvider()

    var hasError: Bool {
        if Settings.showClaude {
            if claudeNote != nil { return true }
            if case .error = claude { return true }
        }
        if Settings.showCodex {
            if codexNote != nil { return true }
            if case .error = codex { return true }
        }
        return false
    }

    /// 服务商被关闭时清掉残留的错误提示，避免隐藏状态继续驱动重试。
    func clearNote(claude: Bool) {
        if claude { claudeNote = nil } else { codexNote = nil }
    }

    /// 服务商开关等设置变化时触发 UI 重渲染。
    @Published var settingsVersion = 0
    func bumpSettings() { settingsVersion += 1 }

    /// 返回 false 表示撞上在飞请求、本次未执行。
    @discardableResult
    func refresh() async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        async let c = Settings.showClaude ? claudeProvider.fetch() : nil
        async let x = Settings.showCodex ? codexProvider.fetch() : nil
        let (claudeResult, codexResult) = await (c, x)
        if let claudeResult {
            (claude, claudeNote) = Self.merge(old: claude, new: claudeResult)
            if case .ok = claudeResult { claudeUpdated = Date() }
            Notifier.check(provider: "Claude", state: claude)
        }
        if let codexResult {
            (codex, codexNote) = Self.merge(old: codex, new: codexResult)
            if case .ok = codexResult { codexUpdated = Date() }
            Notifier.check(provider: "Codex", state: codex)
        }
        lastUpdated = Date()
        refreshing = false
        return true
    }

    /// 任一窗口剩余低于 20% 视为"紧张"，轮询加密到 2 分钟。
    var isTight: Bool {
        let states = (Settings.showClaude ? [claude] : []) + (Settings.showCodex ? [codex] : [])
        for st in states {
            if case .ok(let u) = st {
                for w in [u.hourly, u.weekly] where (w?.remainingPercent ?? 100) < 20 {
                    return true
                }
            }
        }
        return false
    }

    /// 刷新失败时保留上次的好数据，错误降级为提示文字。
    private static func merge(old: ProviderState, new: ProviderState) -> (ProviderState, BiText?) {
        if case .error(let msg) = new, case .ok = old {
            return (old, msg)
        }
        return (new, nil)
    }

    /// 菜单栏数字部分（跟在各自图标后面），窗口按「菜单栏显示」设置选取。
    func statusText(for state: ProviderState) -> String {
        switch state {
        case .loading: return "…"
        case .error: return "!"
        case .ok(let u):
            let window: WindowUsage?
            switch Settings.menuBarMode {
            case .fiveHour: window = u.hourly
            case .weekly: window = u.weekly
            case .lowest, .iconOnly:
                window = [u.hourly, u.weekly].compactMap { $0 }
                    .min { $0.remainingPercent < $1.remainingPercent }
            }
            let fallback: WindowUsage? = Settings.menuBarMode == .fiveHour ? u.weekly : u.hourly
            guard let w = window ?? fallback else { return "?" }
            return "\(Int(w.remainingPercent.rounded()))%"
        }
    }

    /// 当前已知额度中是否存在某个窗口。加载中或出错时保留菜单项可选，避免错误禁用。
    func hasMenuBarWindow(_ mode: Settings.MenuBarMode) -> Bool {
        guard mode == .fiveHour || mode == .weekly else { return true }
        let states = (Settings.showClaude ? [claude] : []) + (Settings.showCodex ? [codex] : [])
        let known = states.compactMap { state -> ProviderUsage? in
            if case .ok(let usage) = state { return usage }
            return nil
        }
        guard !known.isEmpty else { return true }
        return known.contains { usage in
            mode == .fiveHour ? usage.hourly != nil : usage.weekly != nil
        }
    }

    /// 所选窗口在当前服务商都不存在时，切换到唯一可用的窗口。
    @discardableResult
    func normalizeMenuBarMode() -> Bool {
        let mode = Settings.menuBarMode
        guard mode == .fiveHour || mode == .weekly else { return false }
        if hasMenuBarWindow(mode) { return false }
        let fallback: Settings.MenuBarMode = mode == .fiveHour ? .weekly : .fiveHour
        guard hasMenuBarWindow(fallback) else { return false }
        Settings.menuBarMode = fallback
        return true
    }
}
