import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState()
    private var timer: Timer?
    private var hostingItem: NSMenuItem!
    private var refreshItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var langZHItem: NSMenuItem!
    private var langENItem: NSMenuItem!
    private var notifyMenuItem: NSMenuItem!
    private var notifyOffItem: NSMenuItem!
    private var notifyItems: [Int: NSMenuItem] = [:]
    private var displayMenuItem: NSMenuItem!
    private var displayItems: [Settings.MenuBarMode: NSMenuItem] = [:]
    private var showClaudeItem: NSMenuItem!
    private var showCodexItem: NSMenuItem!
    private var claudeLoginItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var titleObserver: Any?

    private static let normalInterval: TimeInterval = 300
    private static let tightInterval: TimeInterval = 120   // 任一窗口剩余 <20% 时
    private var currentInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 应用没有主菜单，⌘C/V/X/A 在文本框里会失效；挂一个隐形编辑菜单让快捷键生效
        let editMenu = NSMenu()
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        Settings.materializeDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusImage()

        let menu = NSMenu()
        menu.autoenablesItems = false   // 手动控制 isEnabled，避免被 autoenable 机制覆盖
        menu.delegate = self

        hostingItem = NSMenuItem()
        let hosting = NSHostingView(rootView: MenuView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: MenuView.panelWidth, height: 220)
        hosting.autoresizingMask = [.width]
        hostingItem.view = hosting
        menu.addItem(hostingItem)

        menu.addItem(.separator())
        refreshItem = menu.addItem(withTitle: "", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        loginItem = menu.addItem(withTitle: "", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self

        displayMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        for mode in Settings.MenuBarMode.allCases {
            let item = displayMenu.addItem(withTitle: "", action: #selector(switchDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            displayItems[mode] = item
        }
        displayMenu.addItem(.separator())
        showClaudeItem = displayMenu.addItem(withTitle: "Claude", action: #selector(toggleClaude), keyEquivalent: "")
        showClaudeItem.target = self
        showCodexItem = displayMenu.addItem(withTitle: "Codex", action: #selector(toggleCodex), keyEquivalent: "")
        showCodexItem.target = self
        displayMenuItem.submenu = displayMenu
        menu.addItem(displayMenuItem)

        notifyMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let notifyMenu = NSMenu()
        notifyMenu.autoenablesItems = false
        notifyOffItem = notifyMenu.addItem(withTitle: "", action: #selector(notifyOff), keyEquivalent: "")
        notifyOffItem.target = self
        notifyMenu.addItem(.separator())
        for t in Settings.allThresholds {
            let item = notifyMenu.addItem(withTitle: "", action: #selector(toggleThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t
            notifyItems[t] = item
        }
        notifyMenuItem.submenu = notifyMenu
        menu.addItem(notifyMenuItem)

        claudeLoginItem = menu.addItem(withTitle: "", action: #selector(claudeLoginOrOut), keyEquivalent: "")
        claudeLoginItem.target = self

        let langItem = NSMenuItem(title: "语言 / Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        langMenu.autoenablesItems = false
        langZHItem = langMenu.addItem(withTitle: "中文", action: #selector(switchToZH), keyEquivalent: "")
        langZHItem.target = self
        langENItem = langMenu.addItem(withTitle: "English", action: #selector(switchToEN), keyEquivalent: "")
        langENItem.target = self
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())
        updateItem = menu.addItem(withTitle: "", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        quitItem = menu.addItem(withTitle: "", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusItem.menu = menu
        updateMenuTitles()

        // 状态变化时更新菜单栏标题
        titleObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatusImage()
                self.resizeHosting()
            }
        }

        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorizationIfNeeded()
        scheduleTimer(interval: Self.normalInterval)
        configureTaskStatusDefaults()
        startStatusTimer()
        Task { await refresh() }
    }

    private var retryScheduled = false
    private var retryDelay: TimeInterval = 30

    private func scheduleTimer(interval: TimeInterval) {
        currentInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let appDelegate = self else { return }
            Task { @MainActor in await appDelegate.refresh() }
        }
    }

    private func refresh() async {
        // 撞上在飞请求时直接返回，不基于陈旧状态做退避/轮询决策
        guard await state.refresh() else { return }
        state.normalizeMenuBarMode()
        updateMenuTitles()
        // 额度紧张时加密轮询到 2 分钟，恢复后退回 5 分钟
        let desired = state.isTight ? Self.tightInterval : Self.normalInterval
        if desired != currentInterval { scheduleTimer(interval: desired) }
        // 失败（如被限流）时自动重试，间隔指数退避（30s → 60s → … → 5min），成功后复位
        if state.hasError {
            guard !retryScheduled else { return }
            retryScheduled = true
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 300)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                Task { @MainActor in await self.refresh() }
            }
        } else {
            retryDelay = 30
        }
    }

    private func resizeHosting() {
        guard let hosting = hostingItem.view as? NSHostingView<MenuView> else { return }
        let size = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: MenuView.panelWidth, height: size.height)
    }

    @objc private func refreshNow() {
        Task { await refresh() }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private var spinnerFrame = 0

    /// 菜单栏服务商图标随任务状态替换：运行=loading 帧，待确认=⚠，空闲/未启用=原 logo(nil)。
    private func stateIcon(_ taskStatus: TaskStatus.State, showProvider: Bool) -> NSImage? {
        guard showProvider else { return nil }
        switch taskStatus {
        case .running: return Icons.spinnerGlyph(frame: spinnerFrame, size: 13)
        case .waiting: return Icons.warningGlyph(size: 12)
        case .idle, .none: return nil
        }
    }

    private var claudeStateIcon: NSImage? {
        stateIcon(state.taskStatus, showProvider: Settings.showClaude)
    }

    private var codexStateIcon: NSImage? {
        stateIcon(state.codexTaskStatus, showProvider: Settings.showCodex)
    }

    private func updateStatusImage() {
        statusItem.button?.title = ""
        statusItem.button?.font = nil

        let iconOnly = Settings.menuBarMode == .iconOnly
        if iconOnly {
            let image = Icons.statusIcon()
            statusItem.length = image.size.width
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
            return
        }

        let image = Icons.statusImage(
            claudeText: state.statusText(for: state.claude),
            codexText: state.statusText(for: state.codex),
            showClaude: Settings.showClaude,
            showCodex: Settings.showCodex,
            claudeIcon: claudeStateIcon,
            codexIcon: codexStateIcon
        )
        statusItem.length = image.size.width
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
    }

    // MARK: - 任务状态轮询

    private var statusTimer: Timer?
    private var codexProbeInFlight = false
    private var lastCodexProbe = Date.distantPast

    private func configureTaskStatusDefaults() {
        guard Settings.showClaude, !TaskStatus.isEnabled else { return }
        try? TaskStatus.enable()
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
        // Claude 状态读本地小 JSON 文件；200ms 只用于菜单栏 loading 动画，Codex 探针另行节流。
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickStatus() }
        }
    }

    private func tickStatus() {
        let claudeNow = Settings.showClaude ? TaskStatus.current() : .none
        spinnerFrame += 1
        if claudeNow != state.taskStatus {
            state.taskStatus = claudeNow
            updateStatusImage()
        } else if claudeNow == .running || state.codexTaskStatus == .running {
            updateStatusImage()
        }
        tickCodexStatusIfNeeded()
    }

    private func tickCodexStatusIfNeeded() {
        guard Settings.showCodex else {
            if state.codexTaskStatus != .none { state.codexTaskStatus = .none; updateStatusImage() }
            return
        }
        guard !codexProbeInFlight, Date().timeIntervalSince(lastCodexProbe) > 2 else { return }
        codexProbeInFlight = true
        lastCodexProbe = Date()
        Task.detached(priority: .utility) {
            let snapshot = CodexTaskStatus.currentSnapshot()
            await MainActor.run {
                self.codexProbeInFlight = false
                if snapshot.state != self.state.codexTaskStatus || snapshot.tasks != self.state.codexTasks {
                    self.state.codexTaskStatus = snapshot.state
                    self.state.codexTasks = snapshot.tasks
                    self.updateStatusImage()
                }
            }
        }
    }

    // MARK: - 菜单栏显示 / 通知

    @objc private func switchDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = Settings.MenuBarMode(rawValue: raw) else { return }
        Settings.menuBarMode = mode
        state.normalizeMenuBarMode()
        updateStatusImage()
        updateMenuTitles()
    }

    @objc private func toggleClaude() { toggleProvider(claude: true) }
    @objc private func toggleCodex() { toggleProvider(claude: false) }

    private func toggleProvider(claude: Bool) {
        // 至少保留一家
        if claude {
            if Settings.showClaude && !Settings.showCodex { NSSound.beep(); return }
            Settings.showClaude.toggle()
            if !Settings.showClaude { state.clearNote(claude: true) }
        } else {
            if Settings.showCodex && !Settings.showClaude { NSSound.beep(); return }
            Settings.showCodex.toggle()
            if !Settings.showCodex { state.clearNote(claude: false) }
        }
        state.bumpSettings()
        if claude, Settings.showClaude { configureTaskStatusDefaults() }
        state.normalizeMenuBarMode()
        updateStatusImage()
        updateMenuTitles()
        resizeHosting()
        Task { await refresh() }
    }

    // MARK: - ByteRate 独立 Claude 登录（解除钥匙串弹框）

    @objc private func claudeLoginOrOut() {
        if ClaudeAuth.hasOwnCredentials {
            ClaudeAuth.logout()
            updateMenuTitles()
            Task { await refresh() }
            return
        }
        let session = ClaudeAuth.beginLogin()
        NSWorkspace.shared.open(session.authorizeURL)

        let alert = NSAlert()
        alert.messageText = L.t("连接 Claude 账号", "Connect your Claude account")
        alert.informativeText = L.t("已在浏览器打开授权页面。完成授权后，把页面显示的授权码粘贴到这里：",
                                    "We've opened the authorization page in your browser. Once you approve, paste the code shown here:")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = L.t("粘贴授权码", "Paste authorization code")
        alert.accessoryView = field
        alert.addButton(withTitle: L.t("完成登录", "Complete sign-in"))
        alert.addButton(withTitle: L.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let code = field.stringValue
        Task { @MainActor in
            do {
                try await ClaudeAuth.completeLogin(pastedCode: code, session: session)
                updateMenuTitles()
                await refresh()   // 面板立即刷出额度，就是最好的"登录成功"反馈
            } catch {
                let err = NSAlert()
                err.messageText = L.t("连接失败，请重试", "Couldn't connect — please try again")
                err.informativeText = (error as? UsageError)?.bi.text ?? error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                err.runModal()
            }
        }
    }

    // MARK: - 检查更新

    @objc private func checkForUpdates() {
        updateItem.isEnabled = false
        Task { @MainActor in
            let result = await UpdateChecker.check()
            updateItem.isEnabled = true
            let alert = NSAlert()
            switch result {
            case .newVersion(let v, let notes):
                alert.messageText = L.t("发现新版本 \(v)", "New version \(v) available")
                var info = L.t("当前版本 \(UpdateChecker.currentVersion)。",
                               "Current version \(UpdateChecker.currentVersion).")
                if let notes {
                    info += "\n\n" + L.t("更新内容：", "What's new:") + "\n" + notes
                }
                alert.informativeText = info
                alert.addButton(withTitle: L.t("立即更新", "Update now"))
                alert.addButton(withTitle: L.t("前往下载", "Open releases"))
                alert.addButton(withTitle: L.t("取消", "Cancel"))
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    runInPlaceUpdate()
                case .alertSecondButtonReturn:
                    if let url = URL(string: UpdateChecker.releasesURL) {
                        NSWorkspace.shared.open(url)
                    }
                default:
                    break
                }
            case .upToDate:
                alert.messageText = L.t("已是最新版本", "You're up to date")
                alert.informativeText = L.t("当前版本 \(UpdateChecker.currentVersion)", "Current version \(UpdateChecker.currentVersion)")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failed(let msg):
                alert.messageText = L.t("检查更新失败", "Update check failed")
                alert.informativeText = msg
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private var isUpdating = false

    /// 在后台跑安装脚本完成一键更新：下载新版 → 替换 → 退出旧实例 → 重启。
    /// 脚本是独立子进程，脚本里的 `pkill -x ByteRate` 只杀本应用、不影响它自己，
    /// 本应用被杀后脚本继续执行并 `open` 新版本。
    private func runInPlaceUpdate() {
        // 防重入：更新已在进行时，再次点击不会启动第二个安装进程（否则两个进程同时 rm/装/重启）
        guard !isUpdating else {
            let busy = NSAlert()
            busy.messageText = L.t("更新进行中", "Update in progress")
            busy.informativeText = L.t("已经在下载安装新版本了，请稍候自动重启。",
                                       "Already downloading and installing — please wait for the relaunch.")
            NSApp.activate(ignoringOtherApps: true)
            busy.runModal()
            return
        }
        isUpdating = true
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        // -lc 走登录 shell，保证 curl 在 PATH 里
        proc.arguments = ["-lc", "curl -fsSL '\(UpdateChecker.installScriptURL)' | bash"]
        do {
            try proc.run()
        } catch {
            isUpdating = false
            let err = NSAlert()
            err.messageText = L.t("更新启动失败", "Couldn't start the update")
            err.informativeText = L.t("请改用「前往下载」手动更新。\n\(error.localizedDescription)",
                                      "Please use \"Open releases\" to update manually.\n\(error.localizedDescription)")
            NSApp.activate(ignoringOtherApps: true)
            err.runModal()
            return
        }
        let info = NSAlert()
        info.messageText = L.t("正在更新…", "Updating…")
        info.informativeText = L.t("正在后台下载并安装新版本，完成后会自动重启 ByteRate。",
                                   "Downloading and installing in the background — ByteRate will relaunch automatically.")
        NSApp.activate(ignoringOtherApps: true)
        info.runModal()
    }

    @objc private func notifyOff() {
        Settings.thresholds = []
        updateMenuTitles()
    }

    @objc private func toggleThreshold(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? Int else { return }
        var set = Settings.thresholds
        if set.contains(t) { set.remove(t) } else { set.insert(t) }
        Settings.thresholds = set
        Notifier.requestAuthorizationIfNeeded()
        updateMenuTitles()
    }

    // MARK: - 语言

    private func updateMenuTitles() {
        statusItem.button?.toolTip = L.t("ByteRate — Claude / Codex 5 小时窗口剩余额度",
                                         "ByteRate — Claude / Codex 5-hour window remaining")
        refreshItem.title = L.t("立即刷新", "Refresh now")
        loginItem.title = L.t("登录时启动", "Launch at login")
        quitItem.title = L.t("退出 ByteRate", "Quit ByteRate")
        langZHItem.state = L.isZH ? .on : .off
        langENItem.state = L.isZH ? .off : .on

        displayMenuItem.title = L.t("菜单栏显示", "Menu bar shows")
        let modeTitles: [Settings.MenuBarMode: String] = [
            .fiveHour: L.t("5 小时窗剩余", "5-hour remaining"),
            .weekly: L.t("周窗剩余", "Weekly remaining"),
            .lowest: L.t("两窗最低值", "Lowest of both"),
            .iconOnly: L.t("纯图标", "Icons only"),
        ]
        for (mode, item) in displayItems {
            item.title = modeTitles[mode] ?? ""
            item.state = Settings.menuBarMode == mode ? .on : .off
            item.isEnabled = state.hasMenuBarWindow(mode)
        }

        showClaudeItem.state = Settings.showClaude ? .on : .off
        showCodexItem.state = Settings.showCodex ? .on : .off
        claudeLoginItem.title = ClaudeAuth.hasOwnCredentials
            ? L.t("断开 Claude 账号", "Disconnect Claude account")
            : L.t("连接 Claude 账号…", "Connect Claude account…")
        claudeLoginItem.isHidden = !Settings.showClaude
        updateItem.title = L.t("检查更新…", "Check for updates…")

        notifyMenuItem.title = L.t("低额度通知", "Low quota alerts")
        notifyOffItem.title = L.t("关闭", "Off")
        notifyOffItem.state = Settings.thresholds.isEmpty ? .on : .off
        for (t, item) in notifyItems {
            item.title = L.t("剩余低于 \(t)%", "Below \(t)% left")
            item.state = Settings.thresholds.contains(t) ? .on : .off
        }
    }

    @objc private func switchToZH() {
        state.setLanguage("zh")
        updateMenuTitles()
        resizeHosting()
    }

    @objc private func switchToEN() {
        state.setLanguage("en")
        updateMenuTitles()
        resizeHosting()
    }

    // MARK: - 登录时启动

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuTitles()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // 以 .app 形式运行才支持登录启动
        loginItem.isEnabled = Bundle.main.bundleIdentifier != nil
        resizeHosting()
        // 数据超过 60 秒则在打开菜单时顺便刷新
        if state.lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            Task { await refresh() }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // App 在前台时也照常展示横幅
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
