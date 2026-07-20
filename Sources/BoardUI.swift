import SwiftUI
import AppKit

// MARK: - Agent Board (floating kanban)

@MainActor
final class BoardController {
    private var window: NSWindow?
    private let monitor: AgentMonitor

    init(monitor: AgentMonitor) { self.monitor = monitor }

    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil); return }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "Agent Board"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.backgroundColor = NSColor.black.withAlphaComponent(0.92)
            w.contentView = NSHostingView(rootView: BoardView(monitor: monitor))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct BoardView: View {
    @ObservedObject var monitor: AgentMonitor

    var active: [AgentSession] { monitor.sessions.filter { $0.state == .working || $0.state == .idle } }
    var attention: [AgentSession] { monitor.sessions.filter { $0.state == .attention } }
    var finished: [AgentSession] { monitor.sessions.filter { $0.state == .finished } }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BoardColumn(title: "Active", color: .green, sessions: active)
            BoardColumn(title: "Attention", color: .orange, sessions: attention)
            BoardColumn(title: "Finished", color: .gray, sessions: finished)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

struct BoardColumn: View {
    let title: String
    let color: Color
    let sessions: [AgentSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text("\(sessions.count)")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.white.opacity(0.12), in: Capsule())
                Spacer()
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(sessions) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(s.project).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(s.kind.rawValue).font(.system(size: 8, weight: .medium))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.white.opacity(0.1), in: Capsule())
                            }
                            if let m = s.model {
                                Text(m.replacingOccurrences(of: "claude-", with: ""))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            if let attn = s.attentionMessage {
                                Text(attn).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
                            } else if !s.lastSnippet.isEmpty {
                                Text(s.lastSnippet).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            HStack {
                                if s.outputTokens > 0 {
                                    Text("\(formatTokens(s.outputTokens)) out").font(.system(size: 8)).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text("\(timeAgo(s.lastActivity)) ago").font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(7)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { Jump.openInTerminal(s.cwd) }
                        .help("Click to open \(s.cwd) in terminal")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Floating widgets (todos / usage / transcript)

@MainActor
final class WidgetController {
    private var windows: [String: NSWindow] = [:]
    private let monitor: AgentMonitor

    init(monitor: AgentMonitor) { self.monitor = monitor }

    private func window(id: String, title: String, size: NSSize, view: some View) {
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); return }
        let w = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        w.title = title
        w.isFloatingPanel = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.92)
        w.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark))
        // stagger placement top-right
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let offset = CGFloat(windows.count) * 30
            w.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24 - offset, y: f.maxY - size.height - 24 - offset))
        }
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }

    func showTodos(for session: AgentSession) {
        window(id: "todos-\(session.sessionId)", title: "Todos · \(session.project)",
               size: NSSize(width: 300, height: 320),
               view: TodoWidget(monitor: monitor, sessionFile: session.id, project: session.project))
    }

    func showTranscript(for session: AgentSession) {
        window(id: "transcript-\(session.sessionId)", title: "Transcript · \(session.project)",
               size: NSSize(width: 420, height: 460),
               view: TranscriptWidget(monitor: monitor, sessionFile: session.id, project: session.project))
    }

    func showUsage() {
        window(id: "usage", title: "Active Usage",
               size: NSSize(width: 360, height: 330),
               view: UsageWidget(monitor: monitor))
    }
}

struct TodoWidget: View {
    @ObservedObject var monitor: AgentMonitor
    let sessionFile: String
    let project: String

    var session: AgentSession? { monitor.sessions.first { $0.id == sessionFile } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let todos = session?.todos, !todos.isEmpty {
                    ForEach(todos) { t in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: t.status == "completed" ? "checkmark.circle.fill"
                                  : t.status == "in_progress" ? "circle.dotted.circle" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(t.status == "completed" ? .green : t.status == "in_progress" ? .yellow : .secondary)
                            Text(t.content).font(.system(size: 11))
                                .foregroundStyle(t.status == "completed" ? .secondary : .primary)
                                .strikethrough(t.status == "completed")
                        }
                    }
                } else {
                    Text("No todos in this session").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TranscriptWidget: View {
    @ObservedObject var monitor: AgentMonitor
    let sessionFile: String
    let project: String
    @State private var items: [TranscriptItem] = []
    @State private var timer: Timer?

    var body: some View {
        TranscriptList(items: items)
            .padding(8)
            .onAppear {
                reload()
                timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
                    Task { @MainActor in reload() }
                }
            }
            .onDisappear { timer?.invalidate() }
    }

    func reload() {
        guard let s = monitor.sessions.first(where: { $0.id == sessionFile }) else { return }
        items = AgentMonitor.transcript(for: s)
    }
}

struct UsageWidget: View {
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatTile(value: formatTokens(monitor.stats.total), label: "tokens · \(monitor.stats.range.rawValue.lowercased())",
                         sub: "\(monitor.stats.requests) requests", accent: .green)
                StatTile(value: formatCost(monitor.stats.estCost), label: "est. value",
                         sub: nil, accent: .orange)
            }
            UsageBarChart(buckets: monitor.stats.buckets)
            UsageBlock(title: "Last 5 hours", usage: monitor.usage5h)
            Spacer()
        }
        .padding(10)
    }
}
