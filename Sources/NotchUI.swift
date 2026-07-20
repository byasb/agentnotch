import SwiftUI
import AppKit

// MARK: - Tabs

enum PanelTab: String, CaseIterable {
    case sessions = "Sessions"
    case usage = "Usage"
    case servers = "Servers"
    case routes = "Routes"
    case actions = "Actions"
    case settings = "Setup"

    var icon: String {
        switch self {
        case .sessions: "bolt.horizontal.circle"
        case .usage: "gauge.with.needle"
        case .servers: "server.rack"
        case .routes: "folder"
        case .actions: "play.circle"
        case .settings: "gearshape"
        }
    }
}

struct AppEnv {
    let monitor: AgentMonitor
    let servers: ServerMonitor
    let actions: ActionStore
    let hooks: HookInstaller
    let widgets: WidgetController
    let system: SystemStats
    let storage: StorageManager
    let openFocus: () -> Void
    let openGames: () -> Void
}

// MARK: - Root panel

struct PanelView: View {
    let env: AppEnv
    var topPadding: CGFloat = 0
    @State private var tab: PanelTab = CommandLine.arguments.contains("--usage") ? .usage
        : CommandLine.arguments.contains("--setup") ? .settings : .sessions

    var body: some View {
        VStack(spacing: 0) {
            TabBar(tab: $tab, monitor: env.monitor)
                .padding(.top, topPadding)
            // Ambient swarm: one mote per live agent, collapses to nothing when idle.
            AgentSwarm(monitor: env.monitor, onTap: { tab = .sessions },
                       onBreathe: env.openFocus, onPlay: env.openGames)
            Divider().opacity(0.25)
            Group {
                switch tab {
                case .sessions: SessionsPage(env: env)
                case .usage: UsagePage(monitor: env.monitor, system: env.system, widgets: env.widgets)
                case .servers: ServersPage(servers: env.servers)
                case .routes: RoutesPage()
                case .actions: ActionsPage(store: env.actions)
                case .settings: SettingsPage(hooks: env.hooks, storage: env.storage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .preferredColorScheme(.dark)
    }
}

struct TabBar: View {
    @Binding var tab: PanelTab
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 11))
                        Text(t.rawValue).font(.system(size: 11, weight: tab == t ? .semibold : .regular))
                        if t == .sessions, monitor.attentionCount > 0 {
                            Text("\(monitor.attentionCount)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(tab == t ? Color.white.opacity(0.12) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == t ? .white : .secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Sessions page

struct SessionsPage: View {
    let env: AppEnv
    @ObservedObject var monitor: AgentMonitor
    @State private var expanded: String?
    @State private var filter = ""

    init(env: AppEnv) {
        self.env = env
        self.monitor = env.monitor
    }

    var filtered: [AgentSession] {
        filter.isEmpty ? monitor.sessions
            : monitor.sessions.filter { $0.project.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Filter projects", text: $filter)
                    .textFieldStyle(.plain).font(.system(size: 11))
                Spacer()
                Text("\(monitor.workingCount) working")
                    .font(.system(size: 10)).foregroundStyle(.green)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10).padding(.top, 8)

            if filtered.isEmpty {
                Text("No recent agent sessions")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(filtered) { s in
                            SessionCard(session: s, env: env,
                                        expanded: expanded == s.id,
                                        toggle: { expanded = expanded == s.id ? nil : s.id })
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
        }
    }
}

struct SessionCard: View {
    let session: AgentSession
    let env: AppEnv
    let expanded: Bool
    let toggle: () -> Void
    @State private var transcript: [TranscriptItem] = []
    @State private var reply = ""
    @State private var sentNote = false

    var stateColor: Color {
        switch session.state {
        case .working: .green
        case .attention: .orange
        case .idle: .yellow.opacity(0.7)
        case .finished: .gray
        }
    }

    var doneTodos: Int { session.todos.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header row
            Button(action: {
                toggle()
                if !expanded { transcript = AgentMonitor.transcript(for: session) }
            }) {
                HStack(spacing: 8) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if let b = session.branch {
                                Label(b, systemImage: "arrow.triangle.branch")
                                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if !session.todos.isEmpty {
                                Text("☑︎ \(doneTodos)/\(session.todos.count)")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Text(session.kind.rawValue)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(.white.opacity(0.1), in: Capsule())
                        }
                        HStack(spacing: 5) {
                            Text(session.state.rawValue).font(.system(size: 10)).foregroundStyle(stateColor)
                            if session.outputTokens > 0 {
                                Text("· \(formatTokens(session.outputTokens)) out").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if let m = session.model {
                                Text("· \(m.replacingOccurrences(of: "claude-", with: ""))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text("· \(timeAgo(session.lastActivity)) ago").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if let attn = session.attentionMessage {
                            Text(attn).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(2)
                        } else if !session.lastSnippet.isEmpty {
                            Text(session.lastSnippet).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(expanded ? 4 : 1)
                        }
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    // actions row
                    HStack(spacing: 6) {
                        SmallButton("Terminal", icon: "terminal") { Jump.openInTerminal(session.cwd) }
                        SmallButton("Finder", icon: "folder") { Jump.reveal(session.cwd) }
                        if !session.todos.isEmpty {
                            SmallButton("Todos ⇱", icon: "checklist") { env.widgets.showTodos(for: session) }
                        }
                        SmallButton("Transcript ⇱", icon: "text.bubble") { env.widgets.showTranscript(for: session) }
                        if let attn = session.attentionMessage {
                            Spacer()
                            SmallButton("Dismiss", icon: "xmark") {
                                EventCenter.shared.dismiss(sessionId: session.sessionId, message: attn)
                            }
                        }
                    }
                    // todos
                    if !session.todos.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(session.todos.prefix(6)) { t in
                                HStack(spacing: 5) {
                                    Image(systemName: t.status == "completed" ? "checkmark.circle.fill"
                                          : t.status == "in_progress" ? "circle.dotted.circle" : "circle")
                                        .font(.system(size: 9))
                                        .foregroundStyle(t.status == "completed" ? .green : t.status == "in_progress" ? .yellow : .secondary)
                                    Text(t.content).font(.system(size: 10)).lineLimit(1)
                                        .foregroundStyle(t.status == "completed" ? .secondary : .primary)
                                }
                            }
                        }
                        .padding(6)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                    // transcript
                    if !transcript.isEmpty {
                        TranscriptList(items: transcript.suffix(12).map { $0 })
                            .frame(maxHeight: 180)
                    }
                    // direct chat
                    HStack(spacing: 6) {
                        TextField("Send a follow-up to this session…", text: $reply)
                            .textFieldStyle(.plain).font(.system(size: 11))
                            .onSubmit(send)
                        Button(action: send) {
                            Image(systemName: sentNote ? "checkmark" : "paperplane.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(sentNote ? .green : .white)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    if sentNote {
                        Text("Sent — reply arrives as a continued session shortly.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9).padding(.bottom, 8)
            }
        }
        .background(.white.opacity(session.state == .attention ? 0.09 : 0.05),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(session.state == .attention ? Color.orange.opacity(0.6) : .clear, lineWidth: 1)
        )
    }

    func send() {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        DirectChat.send(text, to: session)
        reply = ""
        sentNote = true
        Task { try? await Task.sleep(for: .seconds(4)); sentNote = false }
    }
}

struct TranscriptList: View {
    let items: [TranscriptItem]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Text(item.role == "you" ? "YOU" : item.role == "agent" ? "AGENT" : "TOOL")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(item.role == "you" ? .cyan : item.role == "agent" ? .green : .secondary)
                                .frame(width: 38, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                if item.role == "tool" {
                                    HStack(spacing: 4) {
                                        Text(item.text).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        if let d = item.detail {
                                            Text(d).font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                } else {
                                    Text(item.text).font(.system(size: 10)).textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .onAppear { proxy.scrollTo(items.last?.id, anchor: .bottom) }
        }
    }
}

struct SmallButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    init(_ label: String, icon: String, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10))
                .padding(.horizontal, 7).padding(.vertical, 3.5)
                .background(.white.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Usage page (dock.cool-style stat tiles + charts)

struct UsagePage: View {
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject var system: SystemStats
    let widgets: WidgetController

    var sessionsToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return monitor.sessions.filter { $0.lastActivity >= start }.count
    }

    /// The shown stats belong to a different range than the one selected → cold load.
    var coldLoading: Bool { monitor.stats.range != monitor.usageRange && monitor.scanning.active }
    /// Same range, but a background rescan is running → warm refresh (dim, don't blank).
    var warmLoading: Bool { monitor.stats.range == monitor.usageRange && monitor.scanning.active }

    var body: some View {
        VStack(spacing: 0) {
            if monitor.scanning.active {
                ScanProgressBar(progress: monitor.scanning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Claude + Codex").font(.system(size: 12, weight: .semibold))
                        if monitor.scanning.active {
                            ScanBadge(progress: monitor.scanning, range: monitor.usageRange)
                        }
                        Spacer()
                        RangePicker(monitor: monitor)
                        SmallButton("Float ⇱", icon: "macwindow.on.rectangle") { widgets.showUsage() }
                    }
                    if coldLoading {
                        UsageSkeleton()
                    } else {
                        content
                            .opacity(warmLoading ? 0.55 : 1)
                            .animation(.easeInOut(duration: 0.2), value: warmLoading)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder var content: some View {
        StatTileRow(stats: monitor.stats, sessionsToday: sessionsToday, system: system)
        if let limits = monitor.stats.codexLimits {
            CodexLimitsCard(limits: limits)
        }
        HStack(alignment: .top, spacing: 10) {
            UsageBarChart(buckets: monitor.stats.buckets)
            if monitor.stats.range == .d7 {
                ActivityHeatmap(grid: monitor.stats.hourGrid, days: monitor.stats.heatmapDays)
            }
        }
        if !monitor.stats.models.isEmpty {
            ModelShareRow(models: monitor.stats.models)
        }
        UsageBlock(title: "Last 5 hours", usage: monitor.usage5h)
        UsageBlock(title: "Last 24 hours", usage: monitor.usage24h)
        Text("Local session logs, deduplicated by request. Cost is a rough estimate from public per-token pricing — subscription usage may cost nothing extra. Codex 5h/7d gauges come from Codex's own rate-limit reports.")
            .font(.system(size: 9)).foregroundStyle(.tertiary)
    }
}

struct ScanBadge: View {
    let progress: ScanProgress
    let range: UsageRange

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8))
            if progress.total > 0 {
                Text("scanning \(progress.done)/\(progress.total) logs")
            } else {
                Text("scanning \(range == .all ? "all-time" : range.rawValue) history…")
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.green)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.green.opacity(0.12), in: Capsule())
    }
}

struct UsageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in SkeletonBlock(height: 62) }
            }
            HStack(alignment: .top, spacing: 10) {
                SkeletonBlock(height: 110)
                SkeletonBlock(height: 110)
            }
            SkeletonBlock(height: 70)
            SkeletonBlock(height: 70)
            Text("First scan of this range reads every session log, then it's cached — later switches are instant.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

struct RangePicker: View {
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageRange.allCases, id: \.self) { r in
                Button {
                    monitor.usageRange = r
                } label: {
                    Text(r.rawValue)
                        .font(.system(size: 10, weight: monitor.usageRange == r ? .bold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 3.5)
                        .background(monitor.usageRange == r ? Color.white.opacity(0.14) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(monitor.usageRange == r ? .white : .secondary)
            }
        }
        .padding(2)
        .background(.white.opacity(0.05), in: Capsule())
    }
}

struct CodexLimitsCard: View {
    let limits: CodexLimits

    var body: some View {
        HStack(spacing: 14) {
            Text("CODEX LIMITS").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            ForEach(Array(limits.windows.enumerated()), id: \.offset) { _, w in
                limitGauge(w.label, pct: w.pct, resets: w.resets)
            }
            if !limits.plan.isEmpty {
                Text(limits.plan).font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            if Date().timeIntervalSince(limits.reportedAt) > 3600 {
                Text("as of \(limits.reportedAt.formatted(.relative(presentation: .numeric)))")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    func limitGauge(_ label: String, pct: Double, resets: Date) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(pct > 85 ? Color.red : pct > 60 ? .yellow : .green)
                        .frame(width: max(3, geo.size.width * pct / 100))
                }
            }
            .frame(width: 70, height: 5)
            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            if resets > Date() {
                Text("resets \(resets.formatted(.relative(presentation: .numeric)))")
                    .font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

struct StatTileRow: View {
    let stats: UsageStats
    let sessionsToday: Int
    @ObservedObject var system: SystemStats

    var rangeLabel: String { stats.range == .all ? "all-time" : stats.range.rawValue.lowercased() }

    var body: some View {
        HStack(spacing: 8) {
            StatTile(value: formatTokens(stats.total), label: "tokens · \(rangeLabel)",
                     sub: "\(formatTokens(stats.claudeTokens)) Claude · \(formatTokens(stats.codexTokens)) Codex", accent: .green)
            StatTile(value: formatCost(stats.estCost), label: "est. value · \(rangeLabel)",
                     sub: "\(stats.requests) requests", accent: .orange)
            StatTile(value: "\(sessionsToday)", label: "sessions today",
                     sub: nil, accent: .cyan)
            StatTile(value: String(format: "%.0f%%", system.cpuPercent), label: "CPU",
                     sub: String(format: "%.0f / %.0f GB RAM", system.memUsedGB, system.memTotalGB), accent: .purple)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let sub: String?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            if let sub {
                Text(sub).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct UsageBarChart: View {
    let buckets: [Bucket]

    var title: String {
        switch buckets.count {
        case ...8: "BY DAY"
        case ...31: "BY DAY"
        default: "OVER TIME"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                Spacer()
                if let peak = buckets.max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 {
                    Text("peak \(formatTokens(peak.tokens)) · \(peak.label)")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            let maxVal = max(buckets.map(\.tokens).max() ?? 1, 1)
            let compact = buckets.count > 10
            let labelStride = max(1, buckets.count / 8)
            HStack(alignment: .bottom, spacing: compact ? 2 : 6) {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { i, b in
                    VStack(spacing: 3) {
                        if !compact {
                            Text(b.tokens > 0 ? formatTokens(b.tokens) : "")
                                .font(.system(size: 7, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        Capsule()
                            .fill(i == buckets.count - 1 ? Color.green : Color.green.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(3, CGFloat(b.tokens) / CGFloat(maxVal) * 56))
                        Text(i % labelStride == 0 ? b.label : " ")
                            .font(.system(size: 7)).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ActivityHeatmap: View {
    let grid: [[Int]]   // [day][hour]
    let days: [Bucket]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVITY · HOUR × DAY").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            let maxVal = max(grid.flatMap { $0 }.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(grid.enumerated()), id: \.offset) { di, row in
                    HStack(spacing: 2) {
                        Text(days.indices.contains(di) ? days[di].date.formatted(.dateTime.weekday(.narrow)) : "")
                            .font(.system(size: 7)).foregroundStyle(.tertiary).frame(width: 8)
                        ForEach(0..<24, id: \.self) { h in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.green.opacity(row[h] == 0 ? 0.08 : 0.25 + 0.75 * Double(row[h]) / Double(maxVal)))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                HStack(spacing: 2) {
                    Spacer().frame(width: 8)
                    ForEach([0, 6, 12, 18], id: \.self) { h in
                        Text("\(h)").font(.system(size: 7)).foregroundStyle(.tertiary)
                            .frame(width: 9 * 6 - 2, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ModelShareRow: View {
    let models: [(name: String, output: Int)]

    var body: some View {
        HStack(spacing: 8) {
            Text("MODELS").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            ForEach(models.prefix(4), id: \.name) { m in
                HStack(spacing: 4) {
                    Text(m.name.replacingOccurrences(of: "claude-", with: ""))
                        .font(.system(size: 9, weight: .medium)).lineLimit(1)
                    Text(formatTokens(m.output))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.07), in: Capsule())
            }
            Spacer()
        }
    }
}

struct UsageBlock: View {
    let title: String
    let usage: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(usage.requests) requests").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                stat("Output", usage.outputTokens, .green)
                stat("Input", usage.inputTokens, .cyan)
                stat("Cache read", usage.cacheReadTokens, .purple)
                stat("Cache write", usage.cacheCreateTokens, .orange)
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    let total = max(usage.total, 1)
                    bar(usage.outputTokens, total, .green, geo.size.width)
                    bar(usage.inputTokens, total, .cyan, geo.size.width)
                    bar(usage.cacheReadTokens, total, .purple, geo.size.width)
                    bar(usage.cacheCreateTokens, total, .orange, geo.size.width)
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(formatTokens(n)).font(.system(size: 13, weight: .semibold, design: .monospaced))
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    func bar(_ n: Int, _ total: Int, _ color: Color, _ width: CGFloat) -> some View {
        color.frame(width: max(CGFloat(n) / CGFloat(total) * width, n > 0 ? 2 : 0))
    }
}

// MARK: - Servers page

struct ServersPage: View {
    @ObservedObject var servers: ServerMonitor
    @State private var copied: Int?

    var body: some View {
        VStack(spacing: 5) {
            if servers.servers.isEmpty {
                Text("No dev servers on ports 3000–9999")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(servers.servers) { s in
                        HStack(spacing: 8) {
                            Button {
                                NSWorkspace.shared.open(URL(string: s.url)!)
                            } label: {
                                Text("localhost:\(String(s.port))")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.cyan)
                            }
                            .buttonStyle(.plain)
                            if let f = s.framework {
                                Text(f).font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(.white.opacity(0.1), in: Capsule())
                            }
                            Text(s.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            SmallButton(copied == s.port ? "Copied" : "Copy", icon: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s.url, forType: .string)
                                copied = s.port
                            }
                            Button {
                                servers.stop(s)
                            } label: {
                                Image(systemName: "stop.circle").font(.system(size: 13)).foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("Stop pid \(s.id)")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(10)
            }
        }
        .onAppear { servers.refresh() }
    }
}

// MARK: - Routes page

struct RoutesPage: View {
    let routes = Routes.all()

    var grouped: [(String, [Route])] {
        Dictionary(grouping: routes, by: \.agent).sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(grouped, id: \.0) { agent, list in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(agent).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        // labeled rows instead of a bare icon grid — scannable at a glance
                        let cols = [GridItem(.adaptive(minimum: 118), spacing: 5)]
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 5) {
                            ForEach(list) { r in
                                Button { Routes.open(r) } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: r.isFile ? "doc.text" : "folder.fill")
                                            .font(.system(size: 10)).foregroundStyle(.cyan)
                                        Text(r.label).font(.system(size: 11)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(r.path)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Actions page

struct ActionsPage: View {
    @ObservedObject var store: ActionStore
    @State private var name = ""
    @State private var command = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 11)).frame(width: 100)
                TextField("shell command, e.g. npm run build", text: $command)
                    .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                Button {
                    guard !name.isEmpty, !command.isEmpty else { return }
                    store.add(name: name, command: command)
                    name = ""; command = ""
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(name.isEmpty || command.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if store.actions.isEmpty {
                Text("Save the shell commands you run most.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 14)
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.actions) { a in
                        let isRunning = store.running[a.id] != nil
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).font(.system(size: 12, weight: .semibold))
                                Text(a.command).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if isRunning {
                                Text("running").font(.system(size: 9)).foregroundStyle(.green)
                            }
                            Button {
                                isRunning ? store.stop(a) : store.run(a)
                            } label: {
                                Image(systemName: isRunning ? "stop.circle.fill" : "play.circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(isRunning ? .red : .green)
                            }
                            .buttonStyle(.plain)
                            Button { store.remove(a) } label: {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
        .padding(10)
    }
}

// MARK: - Settings / Setup page

struct SettingsPage: View {
    @ObservedObject var hooks: HookInstaller
    @ObservedObject var storage: StorageManager
    @State private var error: String?
    @State private var confirming: StorageCategory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: hooks.installed ? "checkmark.seal.fill" : "seal")
                            .foregroundStyle(hooks.installed ? .green : .secondary)
                        Text("Claude Code hook").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button(hooks.installed ? "Remove" : "Install") {
                            do {
                                hooks.installed ? try hooks.uninstall() : try hooks.install()
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                        .font(.system(size: 11))
                    }
                    Text("Adds a non-blocking event logger to ~/.claude/settings.json (Notification, Stop, UserPromptSubmit). Lets AgentNotch flag sessions waiting on permissions the moment they ask. Backs up settings first. New sessions pick it up; running ones after restart.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
                }
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

                StorageSection(storage: storage, confirming: $confirming)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Everything stays on this Mac").font(.system(size: 11, weight: .semibold))
                    Text("AgentNotch reads local session files only. No network, no accounts, no telemetry.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
            .padding(12)
        }
        .onAppear { if storage.categories.isEmpty { storage.scan() } }
        .confirmationDialog(confirming?.title ?? "", isPresented: .init(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { cat in
            Button("Remove \(formatBytes(cat.bytes))", role: .destructive) {
                storage.clean(cat); confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { cat in
            Text(cat.warning ?? cat.detail)
        }
    }
}

struct StorageSection: View {
    @ObservedObject var storage: StorageManager
    @Binding var confirming: StorageCategory?

    var safe: [StorageCategory] { storage.categories.filter { $0.tier == .safe } }
    var caution: [StorageCategory] { storage.categories.filter { $0.tier == .caution } }
    var safeBytes: Int64 { safe.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text("Storage").font(.system(size: 12, weight: .semibold))
                Spacer()
                if storage.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Rescan") { storage.scan() }.font(.system(size: 10))
                }
            }
            if let freed = storage.lastFreed {
                Text("Freed \(formatBytes(freed)).")
                    .font(.system(size: 10)).foregroundStyle(.green)
            }

            // Safe: one-click, low risk
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Regenerable cache").font(.system(size: 11, weight: .medium))
                    Text("Safe to clear — Claude Code rebuilds it on demand.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clean \(formatBytes(safeBytes))") { storage.cleanAllSafe() }
                    .font(.system(size: 11))
                    .disabled(safeBytes == 0)
            }
            .padding(9)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            // Caution: per-item, each behind a confirm with its own warning
            if !caution.isEmpty {
                Text("RECLAIMABLE — WITH A TRADE-OFF")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    .padding(.top, 2)
                ForEach(caution) { cat in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(.yellow.opacity(0.8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cat.title).font(.system(size: 11, weight: .medium))
                            Text(cat.detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(formatBytes(cat.bytes))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Button("Remove") { confirming = cat }
                            .font(.system(size: 10))
                            .disabled(cat.bytes == 0)
                    }
                    .padding(9)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text("Your session history, plugins, command logs, pastes, and login records are never offered here — they're your data or things running agents still need. Big space users are usually session history and installed plugins, which stay put.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Notch panel

@MainActor
final class NotchPanelController {
    private var panel: NSPanel?
    private let env: AppEnv
    private var pollTimer: Timer?
    private(set) var visible = false
    private var pinned = false // shown via toggle/menu: ignore hover-out until toggled again

    init(env: AppEnv) {
        self.env = env
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkMouse()
        }
    }

    private var panelWidth: CGFloat { 680 }
    private var panelHeight: CGFloat { 440 }

    private func notchTriggerRect(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        return NSRect(x: f.midX - 130, y: f.maxY - 36, width: 260, height: 36)
    }

    private func checkMouse() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        if !visible, notchTriggerRect(on: screen).contains(mouse) {
            show(on: screen)
        } else if visible, !pinned, let p = panel {
            let keep = p.frame.insetBy(dx: -40, dy: -40)
            if !keep.contains(mouse), !notchTriggerRect(on: screen).contains(mouse) {
                hide()
            }
        }
    }

    func toggle() {
        if visible {
            pinned = false
            hide()
        } else if let s = NSScreen.main {
            pinned = true
            show(on: s)
        }
    }

    /// Open the notch panel (used when the game jumps to an attention session).
    func showSessions() {
        if let s = NSScreen.main {
            pinned = true
            if !visible { show(on: s) }
        }
    }

    private func show(on screen: NSScreen) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let f = screen.frame
        panel.setFrame(
            NSRect(x: f.midX - panelWidth / 2, y: f.maxY - panelHeight, width: panelWidth, height: panelHeight),
            display: true
        )
        panel.orderFrontRegardless()
        panel.makeKey()
        visible = true
        env.monitor.panelVisible = true
    }

    private func hide() {
        panel?.orderOut(nil)
        visible = false
        env.monitor.panelVisible = false
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView:
            PanelView(env: env, topPadding: 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                        .fill(Color.black)
                )
        )
        p.contentView = host
        return p
    }
}
