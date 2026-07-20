import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = AgentMonitor()
    let servers = ServerMonitor()
    let actions = ActionStore()
    let hooks = HookInstaller()
    let system = SystemStats()
    let storage = StorageManager()
    var widgets: WidgetController!
    var board: BoardController!
    var focus: FocusController!
    var games: GamesController!
    var env: AppEnv!
    var statusItem: NSStatusItem!
    var notch: NotchPanelController!
    var popover: NSPopover!
    var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        monitor.start()
        servers.start()
        system.start()
        widgets = WidgetController(monitor: monitor)
        board = BoardController(monitor: monitor)
        focus = FocusController(monitor: monitor)
        games = GamesController(monitor: monitor)
        env = AppEnv(monitor: monitor, servers: servers, actions: actions, hooks: hooks, widgets: widgets, system: system, storage: storage, openFocus: { [weak self] in self?.focus.toggle() }, openGames: { [weak self] in self?.games.toggle() })
        notch = NotchPanelController(env: env)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PanelView(env: env)
                .frame(width: 560, height: 460)
        )

        updateTitle()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        if CommandLine.arguments.contains("--all-range") {
            monitor.usageRange = .all
        }
        if CommandLine.arguments.contains("--focus") {
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); self.focus.toggle() }
        }
        if CommandLine.arguments.contains("--games") {
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); self.games.toggle() }
        }
        if CommandLine.arguments.contains("--show") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.notch.toggle()
            }
        }
    }

    func updateTitle() {
        let working = monitor.workingCount
        let attention = monitor.attentionCount
        let symbol = NSImage(systemSymbolName: attention > 0 ? "bell.badge.fill" : "brain.filled.head.profile",
                             accessibilityDescription: "AgentNotch")
        statusItem.button?.image = symbol
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.contentTintColor = attention > 0 ? .orange : nil
        statusItem.button?.title = working > 0 ? " \(working)" : ""
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Toggle Notch Panel", action: #selector(toggleNotch), keyEquivalent: "n")
            menu.addItem(withTitle: "Agent Board", action: #selector(toggleBoard), keyEquivalent: "b")
            menu.addItem(withTitle: "Usage Widget", action: #selector(showUsageWidget), keyEquivalent: "u")
            menu.addItem(withTitle: "Focus space", action: #selector(openFocus), keyEquivalent: "f")
            menu.addItem(withTitle: "Games", action: #selector(openGames), keyEquivalent: "p")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit AgentNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            menu.items.last?.target = nil
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
            monitor.panelVisible = false
        } else {
            monitor.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            monitor.panelVisible = true
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in monitor.panelVisible = false }
    }

    @objc func toggleNotch() { notch.toggle() }
    @objc func toggleBoard() { board.toggle() }
    @objc func showUsageWidget() { widgets.showUsage() }
    @objc func openFocus() { focus.toggle() }
    @objc func openGames() { games.toggle() }
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--cli") {
                let m = AgentMonitor()
                m.refresh()
                print("Sessions (\(m.sessions.count)):")
                for s in m.sessions.prefix(15) {
                    let todo = s.todos.isEmpty ? "" : " todos=\(s.todos.filter { $0.status == "completed" }.count)/\(s.todos.count)"
                    print("  [\(s.kind.rawValue)] \(s.project) \(s.branch ?? "-") \(s.state.rawValue) out=\(formatTokens(s.outputTokens))\(todo)")
                }
                let range: UsageRange = CommandLine.arguments.contains("--all-time") ? .all : .d7
                let st = UsageEngine.shared.compute(claudeDir: m.claudeProjects, codexDir: m.codexSessions, range: range)
                let u = st.s5h
                print("Usage 5h: in=\(formatTokens(u.inputTokens)) out=\(formatTokens(u.outputTokens)) cacheR=\(formatTokens(u.cacheReadTokens)) cacheW=\(formatTokens(u.cacheCreateTokens)) req=\(u.requests)")
                print("\(range.rawValue): total=\(formatTokens(st.total)) claude=\(formatTokens(st.claudeTokens)) codex=\(formatTokens(st.codexTokens)) req=\(st.requests) estCost=\(formatCost(st.estCost))")
                print("Buckets: " + st.buckets.suffix(12).map { "\($0.label)=\(formatTokens($0.tokens))" }.joined(separator: " "))
                if let l = st.codexLimits {
                    print("Codex limits: " + l.windows.map { "\($0.label)=\(Int($0.pct))%" }.joined(separator: " ") + " plan=\(l.plan)")
                }
                print("Models: " + st.models.prefix(3).map { "\($0.name)=\(formatTokens($0.output))" }.joined(separator: " "))
                print("Servers:")
                for s in ServerMonitor.scan() {
                    print("  :\(s.port) \(s.framework ?? s.command) \(s.project) pid=\(s.id)")
                }
                print("Routes: \(Routes.all().map { "\($0.agent)/\($0.label)" }.joined(separator: ", "))")
                exit(0)
            }
            let delegate = AppDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
        }
    }
}
