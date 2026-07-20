import Foundation
import AppKit

// MARK: - Event center: reads events written by the Claude Code hook

/// The hook (installed opt-in) appends one JSON line per Notification/Stop event
/// to ~/.agentnotch/events.jsonl. Non-blocking (async:true, appends and exits),
/// so it can never slow the user's agent sessions down.
final class EventCenter: @unchecked Sendable {
    static let shared = EventCenter()
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentnotch")
    var eventsFile: URL { dir.appendingPathComponent("events.jsonl") }
    private var dismissed = Set<String>()

    /// sessionId -> permission/attention message, from recent Notification events.
    /// A Stop or newer activity clears it implicitly (session mtime moves on).
    func pendingAttention() -> [String: String] {
        guard let text = try? String(contentsOf: eventsFile, encoding: .utf8) else { return [:] }
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var pending: [String: String] = [:]
        for line in text.split(separator: "\n").suffix(400) {
            guard let data = line.data(using: .utf8),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = d["session_id"] as? String else { continue }
            let event = d["hook_event_name"] as? String
            if let ts = d["agentnotch_ts"] as? String, let date = iso.date(from: ts), date < cutoff { continue }
            switch event {
            case "Notification":
                let msg = d["message"] as? String ?? "Waiting for your input"
                if !dismissed.contains(sid + msg) { pending[sid] = msg }
            case "Stop", "UserPromptSubmit":
                pending[sid] = nil
            default: break
            }
        }
        return pending
    }

    func dismiss(sessionId: String, message: String) {
        dismissed.insert(sessionId + message)
    }
}

// MARK: - Hook installer

@MainActor
final class HookInstaller: ObservableObject {
    @Published var installed = false
    private let fm = FileManager.default
    private let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private var scriptURL: URL { EventCenter.shared.dir.appendingPathComponent("hook.sh") }
    private let marker = ".agentnotch/hook.sh"

    init() { installed = checkInstalled() }

    func checkInstalled() -> Bool {
        guard let s = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return s.contains(marker) && fm.fileExists(atPath: scriptURL.path)
    }

    /// Installs a tiny append-only event logger into Claude Code's Notification,
    /// Stop and UserPromptSubmit hooks. async, 5s timeout, exits immediately —
    /// cannot block or slow sessions. Backs up settings.json first.
    func install() throws {
        try fm.createDirectory(at: EventCenter.shared.dir, withIntermediateDirectories: true)
        let script = """
        #!/bin/zsh
        # AgentNotch event logger: appends the hook payload, never blocks.
        input=$(cat)
        ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
        echo "${input%\\}},\\"agentnotch_ts\\":\\"$ts\\"}" >> ~/.agentnotch/events.jsonl 2>/dev/null
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let data = try Data(contentsOf: settingsURL)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AgentNotch", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json not an object"])
        }
        // backup once per install
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.agentnotch-backup")
        try? data.write(to: backup)

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let entry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": "~/" + marker, "timeout": 5, "async": true]]
        ]
        for event in ["Notification", "Stop", "UserPromptSubmit"] {
            var arr = hooks[event] as? [[String: Any]] ?? []
            let already = arr.contains { (try? JSONSerialization.data(withJSONObject: $0))
                .flatMap { String(data: $0, encoding: .utf8) }?.contains(marker) == true }
            if !already { arr.append(entry) }
            hooks[event] = arr
        }
        settings["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL)
        installed = true
    }

    func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            arr.removeAll { (try? JSONSerialization.data(withJSONObject: $0))
                .flatMap { String(data: $0, encoding: .utf8) }?.contains(marker) == true }
            hooks[event] = arr
        }
        settings["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL)
        installed = false
    }
}

// MARK: - Direct chat: send a follow-up prompt into a resumable session

enum DirectChat {
    /// Fire-and-forget `claude --resume <id> -p "<text>"` in the session's cwd.
    /// The reply lands in a continuation JSONL that the monitor picks up.
    /// Deliberately NO --permission-mode override: the resumed turn runs with
    /// Claude Code's default (deny-in-headless) permissions, so a prompt typed
    /// into the notch can never silently edit files.
    static func send(_ text: String, to session: AgentSession) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let cmd: String
        switch session.kind {
        case .claude:
            cmd = "claude --resume \(session.sessionId) -p \(shellQuote(text)) >/dev/null 2>&1"
        case .codex:
            cmd = "codex exec resume \(session.sessionId) \(shellQuote(text)) >/dev/null 2>&1"
        }
        p.arguments = ["-lc", cmd]
        if !session.cwd.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: session.cwd) }
        try? p.run()
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Jump to terminal / Finder

enum Jump {
    static func openInTerminal(_ path: String) {
        guard !path.isEmpty else { return }
        let candidates = ["Warp", "iTerm", "Ghostty", "kitty", "WezTerm", "Terminal"]
        let app = candidates.first { FileManager.default.fileExists(atPath: "/Applications/\($0).app") } ?? "Terminal"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app, path]
        try? p.run()
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (path as NSString).expandingTildeInPath)
    }
}
