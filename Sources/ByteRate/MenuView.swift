import SwiftUI

/// 下拉面板：两家额度同屏展示。
struct MenuView: View {
    static let panelWidth: CGFloat = 300

    @ObservedObject var state: AppState
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if Settings.showClaude {
                ProviderSection(title: "Claude", icon: Image(nsImage: Icons.claude(size: 16)), iconIsTemplate: false, state: state.claude, note: state.claudeNote, updated: state.claudeUpdated, refreshing: state.refreshing, now: now, taskStatus: state.taskStatus)
            }
            if Settings.showClaude && Settings.showCodex {
                Divider()
            }
            if Settings.showCodex {
                ProviderSection(title: "Codex", icon: Image(nsImage: Icons.openAI(size: 16)), iconIsTemplate: true, state: state.codex, note: state.codexNote, updated: state.codexUpdated, refreshing: state.refreshing, now: now, taskStatus: state.codexTaskStatus, taskTitles: state.codexTasks, showTaskStatusInHeader: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.panelWidth, alignment: .leading)
        .onReceive(clock) { now = $0 }
    }
}

private struct ProviderSection: View {
    let title: String
    let icon: Image
    let iconIsTemplate: Bool
    let state: ProviderState
    let note: BiText?
    let updated: Date?
    let refreshing: Bool
    let now: Date
    var taskStatus: TaskStatus.State = .none
    var taskTitles: [String] = []
    var showTaskStatusInHeader = true

    private func isPaidPlan(_ plan: String?) -> Bool {
        guard let p = plan?.lowercased() else { return false }
        return ["plus", "pro", "max", "team", "enterprise", "business"].contains(p)
    }

    /// 头部图标按任务状态替换：运行=转圈，待确认=橙色警示，空闲/未启用=服务商 logo。
    @ViewBuilder private var headerIcon: some View {
        switch taskStatus {
        case .running:
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        case .waiting:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14)).foregroundStyle(.orange).frame(width: 16, height: 16)
        case .idle, .none:
            if iconIsTemplate { icon.renderingMode(.template).foregroundStyle(.primary) } else { icon }
        }
    }

    @ViewBuilder private var taskDetails: some View {
        if !taskTitles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(taskTitles.prefix(3).enumerated()), id: \.offset) { _, title in
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(title).lineLimit(1)
                    }
                }
                if taskTitles.count > 3 {
                    Text(L.t("还有 \(taskTitles.count - 3) 个任务运行中", "+\(taskTitles.count - 3) more running"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if showTaskStatusInHeader { headerIcon } else if iconIsTemplate { icon.renderingMode(.template).foregroundStyle(.primary) } else { icon }
                Text(title).font(.headline)
                if case .ok(let u) = state, let plan = u.plan {
                    Text(plan.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if taskStatus == .waiting {
                    Text(L.t("待确认", "Needs you")).font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                // 到期日仅 Codex 有（来自 id_token）。OpenAI 端的日期可能滞后，故：
                // 未来日期 → 显示到期日；已过去但仍是付费档 → 说明已续费、显示"订阅有效"；
                // 真到期则 plan_type 会降为 free，这里都不显示，徽章会变成 Free
                if case .ok(let u) = state, let expiry = u.planExpiresAt {
                    if expiry.timeIntervalSince(now) > 0 {
                        Text(L.t("订阅 \(expiry.expiryDescription) 到期", "Plan expires \(expiry.expiryDescription)"))
                            .font(.caption2)
                            .foregroundStyle(expiry.timeIntervalSince(now) < 3 * 86400 ? .orange : .secondary)
                    } else if isPaidPlan(u.plan) {
                        Text(L.t("订阅有效", "Active"))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            Group {
                if refreshing {
                    Text(L.t("刷新中…", "refreshing…"))
                } else if let updated {
                    Text("\(L.t("更新于", "Updated")) \(updated.timeDescription)")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.top, 1)
            taskDetails
            switch state {
            case .loading:
                Text(L.t("加载中…", "Loading…")).font(.caption).foregroundStyle(.secondary)
            case .error(let msg):
                Text(msg.text).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .ok(let usage):
                if let h = usage.hourly { UsageRow(label: L.t("5 小时", "5-hour"), usage: h, now: now) }
                if let w = usage.weekly { UsageRow(label: L.t("每周", "Weekly"), usage: w, now: now) }
                if usage.hourly == nil && usage.weekly == nil {
                    Text(L.t("没有返回额度数据", "No quota data returned")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note {
                Text(L.t("刷新失败：\(note.text)，显示的是上次数据，稍后自动重试",
                         "Refresh failed: \(note.text) — showing last data, will retry"))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UsageRow: View {
    let label: String
    let usage: WindowUsage
    let now: Date

    private var barColor: Color {
        switch usage.remainingPercent {
        case ..<15: return .red
        case ..<40: return .orange
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(usage.remainingPercent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barColor)
            }
            BurnBar(remaining: usage.remainingPercent / 100, color: barColor)
                .frame(height: 5)
            if let r = usage.resetsAt {
                let duration = Text(r.remainingDescription(from: now))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                if L.isZH {
                    (duration
                     + Text(" 后重置（\(r.resetDescription)）")
                        .font(.caption2)
                        .foregroundColor(.secondary))
                } else {
                    (Text("Resets in ")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                     + duration
                     + Text(" (\(r.resetDescription))")
                        .font(.caption2)
                        .foregroundColor(.secondary))
                }
            }
        }
    }
}

/// 从右往左的额度条：右侧彩色 = 剩余额度，左侧淡灰 = 已消耗。
private struct BurnBar: View {
    let remaining: Double   // 0–1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.65), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: remaining <= 0 ? 0 : max(geo.size.height, geo.size.width * remaining))
            }
        }
    }
}
