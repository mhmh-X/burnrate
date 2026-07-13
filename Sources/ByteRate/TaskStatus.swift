import Foundation

/// Claude Code 任务状态：轮询 hook 写的 per-session 状态文件，聚合成一个总状态。
/// 只读状态文件，不碰凭据或对话内容。
enum TaskStatus {
    enum State {
        case none      // 未启用 / 没有活跃会话
        case idle      // 有会话但空闲
        case running   // 至少一个会话在跑
        case waiting   // 至少一个会话停下等确认（权限/输入）——最要紧
    }

    static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ByteRate")
    }
    private static var statusDir: URL { appSupport.appendingPathComponent("status") }
    static var hookScriptPath: URL { appSupport.appendingPathComponent("claude-status-hook.mjs") }

    private static let staleAfter: TimeInterval = 12 * 3600  // 崩溃残留清理

    /// 是否已装 hook（脚本在 + settings.json 里有引用）。
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: hookScriptPath.path)
            && (try? String(contentsOf: settingsURL))?.contains("claude-status-hook.mjs") == true
    }

    /// 聚合当前状态。
    static func current() -> State {
        guard isEnabled,
              let files = try? FileManager.default.contentsOfDirectory(at: statusDir,
                                                                       includingPropertiesForKeys: nil)
        else { return .none }
        var hasRunning = false, hasWaiting = false, hasAny = false
        let now = Date().timeIntervalSince1970 * 1000
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = j["state"] as? String,
                  let ts = j["ts"] as? Double, now - ts < staleAfter * 1000 else {
                try? FileManager.default.removeItem(at: f)  // 坏或过期，清掉
                continue
            }
            hasAny = true
            if state == "waiting" { hasWaiting = true }
            else if state == "running" { hasRunning = true }
        }
        if hasWaiting { return .waiting }
        if hasRunning { return .running }
        return hasAny ? .idle : .none
    }

    // MARK: - 安装 / 卸载 hook

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// 事件 → 状态映射。
    private static let eventStates: [(event: String, state: String)] = [
        ("UserPromptSubmit", "running"),
        ("PreToolUse", "running"),
        ("Notification", "waiting"),
        ("Stop", "idle"),
        ("SessionEnd", "end"),
    ]

    /// 装 hook：拷脚本 + 合并进 settings.json（保留用户已有 hook，幂等）。
    static func enable() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let src = Bundle.main.url(forResource: "claude-status-hook", withExtension: "mjs") else {
            throw UsageError.message("找不到 hook 脚本资源", "Hook script resource missing")
        }
        try? FileManager.default.removeItem(at: hookScriptPath)
        try FileManager.default.copyItem(at: src, to: hookScriptPath)

        let node = resolveNodePath()
        var root = readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, state) in eventStates {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let cmd = "\(node) \"\(hookScriptPath.path)\" \(state)"
            let alreadyHas = groups.contains { g in
                (g["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains("claude-status-hook.mjs") == true
                } == true
            }
            if !alreadyHas {
                groups.append(["hooks": [["type": "command", "command": cmd]]])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    /// 卸载：从 settings.json 删掉我们的条目 + 删脚本和状态文件。
    static func disable() throws {
        var root = readSettings()
        if var hooks = root["hooks"] as? [String: Any] {
            for (event, _) in eventStates {
                guard var groups = hooks[event] as? [[String: Any]] else { continue }
                groups.removeAll { g in
                    (g["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("claude-status-hook.mjs") == true
                    } == true
                }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        try writeSettings(root)
        try? FileManager.default.removeItem(at: hookScriptPath)
        try? FileManager.default.removeItem(at: statusDir)
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        // 写前留一份备份，改的是用户自己的 settings.json
        if let cur = try? Data(contentsOf: settingsURL) {
            try? cur.write(to: settingsURL.appendingPathExtension("byterate-bak"))
        }
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// hook 在 Claude 的 shell 里跑，node 未必在 PATH——安装时用登录 shell 解析绝对路径。
    private static func resolveNodePath() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "which node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? "node" : out
    }
}

/// Codex 任务状态：只读会话文件末尾事件和任务标题片段。
/// app-server 独立进程目前只能看到 notLoaded，拿不到桌面端活跃 thread；这里读文件末尾事件兜住 running。
enum CodexTaskStatus {
    struct Snapshot {
        let state: TaskStatus.State
        let tasks: [String]
    }

    private enum SessionEvent {
        case started(Date, String?)
        case completed
    }

    private static let activeAfterWrite: TimeInterval = 20
    private static let staleStartedAfter: TimeInterval = 2 * 3600
    private static let tailBytes = 128 * 1024

    static func current() -> TaskStatus.State {
        currentSnapshot().state
    }

    static func currentSnapshot() -> Snapshot {
        let now = Date()
        let active = sessionFiles().compactMap { file, modified -> (Date, String)? in
            switch lastSessionEvent(in: file) {
            case .started(let started, let title) where now.timeIntervalSince(started) < staleStartedAfter:
                return (started, title ?? "Codex")
            case .completed:
                return nil
            case .started:
                return nil
            case .none:
                guard now.timeIntervalSince(modified) <= activeAfterWrite else { return nil }
                return (modified, latestTitle(in: file) ?? "Codex")
            }
        }.sorted { $0.0 > $1.0 }

        return Snapshot(state: active.isEmpty ? .none : .running,
                        tasks: active.map(\.1))
    }

    private static func sessionFiles() -> [(URL, Date)] {
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let files = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [(URL, Date)] = []
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            result.append((file, modified))
        }
        return result
    }

    private static func lastSessionEvent(in file: URL) -> SessionEvent? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return nil }

        let lines = text.split(whereSeparator: \.isNewline)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var latestEvent: SessionEvent?
        var latestTitle: String?

        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any] else { continue }
            if root["type"] as? String == "response_item",
               payload["role"] as? String == "user",
               let title = userMessageText(payload) {
                latestTitle = title
            }
            guard root["type"] as? String == "event_msg",
                  let type = payload["type"] as? String else { continue }
            if type == "task_complete" {
                latestEvent = .completed
            }
            if type == "task_started" {
                var started = Date()
                if let raw = payload["started_at"] as? String,
                   let date = formatter.date(from: raw) {
                    started = date
                } else if let raw = root["timestamp"] as? String,
                          let date = formatter.date(from: raw) {
                    started = date
                }
                latestEvent = .started(started, nil)
            }
        }
        if case .started(let started, _) = latestEvent {
            return .started(started, latestTitle)
        }
        return latestEvent
    }

    private static func latestTitle(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["type"] as? String == "response_item",
                  let payload = root["payload"] as? [String: Any],
                  payload["role"] as? String == "user" else { continue }
            if let title = userMessageText(payload) { return title }
        }
        return nil
    }

    private static func userMessageText(_ payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [Any] else { return nil }
        let text = content.compactMap { ($0 as? [String: Any])?["text"] as? String }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count <= 80 { return text }
        return String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
