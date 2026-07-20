import Foundation

// MARK: - Model

enum AgentKind: String {
    case claude = "Claude"
    case codex = "Codex"
}

enum SessionState: String {
    case working = "Working"
    case attention = "Needs you"
    case idle = "Idle"
    case finished = "Finished"
}

struct TodoItem: Identifiable {
    let id: String
    let content: String
    let status: String // pending | in_progress | completed
}

struct TranscriptItem: Identifiable {
    let id: String
    let role: String        // "you" | "agent" | "tool"
    let text: String
    let detail: String?     // tool input summary
    let timestamp: Date?
}

struct AgentSession: Identifiable {
    let id: String          // filename
    let sessionId: String   // provider uuid
    let kind: AgentKind
    let project: String
    let cwd: String
    let branch: String?
    let model: String?
    var state: SessionState
    let lastActivity: Date
    let lastSnippet: String
    let outputTokens: Int
    let fileURL: URL
    let todos: [TodoItem]
    var attentionMessage: String?
}

struct UsageSummary {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreateTokens = 0
    var requests = 0
    var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens }
}

// MARK: - Monitor

@MainActor
final class AgentMonitor: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var usage5h = UsageSummary()
    @Published var usage24h = UsageSummary()
    @Published var stats = UsageStats()
    @Published var usageRange: UsageRange = .d7 {
        didSet { if oldValue != usageRange { scanning = ScanProgress(); recomputeUsage() } }
    }
    /// Live scan progress for the current usage recompute (drives the range loader).
    @Published var scanning = ScanProgress()
    /// True only while a panel/popover surface is actually on screen. Gates the
    /// swarm animation so its display link never runs against a hidden window.
    @Published var panelVisible = false

    private let fm = FileManager.default
    private var timer: Timer?
    private var usageTick = 0
    let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")
    let codexSessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var attentionCount: Int { sessions.filter { $0.state == .attention }.count }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        var found: [AgentSession] = []
        found += scanClaude()
        found += scanCodex()
        // Overlay hook-reported attention (permission prompts) on top of mtime heuristics
        let pending = EventCenter.shared.pendingAttention()
        for i in found.indices {
            if let msg = pending[found[i].sessionId], found[i].state != .finished {
                found[i].state = .attention
                found[i].attentionMessage = msg
            }
        }
        sessions = found.sorted {
            if ($0.state == .attention) != ($1.state == .attention) { return $0.state == .attention }
            return $0.lastActivity > $1.lastActivity
        }
        usageTick += 1
        if usageTick % 10 == 1 { recomputeUsage() } // every ~30s (cached per file, off main)
    }

    func recomputeUsage() {
        let claude = claudeProjects, codex = codexSessions, range = usageRange
        Task.detached(priority: .utility) {
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor in
                    guard self.usageRange == range else { return }
                    self.scanning = ScanProgress(done: done, total: total, active: done < total)
                }
            }
            let stats = UsageEngine.shared.compute(claudeDir: claude, codexDir: codex,
                                                   range: range, progress: progress)
            await MainActor.run {
                guard self.usageRange == range else { return } // stale result, newer range pending
                self.stats = stats
                self.usage5h = stats.s5h
                self.usage24h = stats.s24h
                self.scanning = ScanProgress(done: stats.range == range ? 1 : 0, total: 0, active: false)
            }
        }
    }

    // MARK: Claude Code (~/.claude/projects/<dir>/<uuid>.jsonl)

    private func scanClaude() -> [AgentSession] {
        guard let dirs = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: nil) else { return [] }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        var out: [AgentSession] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > cutoff else { continue }
                if let s = parseClaudeSession(file: file, mtime: mtime) { out.append(s) }
            }
        }
        return out
    }

    private func parseClaudeSession(file: URL, mtime: Date) -> AgentSession? {
        guard let lines = tailLines(of: file, maxBytes: 192 * 1024) else { return nil }
        var cwd: String?, branch: String?, model: String?, snippet = "", tokens = 0
        var sessionId = file.deletingPathExtension().lastPathComponent
        var todos: [TodoItem] = []
        var sawRealTurn = false
        for line in lines {
            guard let d = jsonObject(line) else { continue }
            let type = d["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            sawRealTurn = true
            cwd = d["cwd"] as? String ?? cwd
            branch = d["gitBranch"] as? String ?? branch
            sessionId = d["sessionId"] as? String ?? sessionId
            if let msg = d["message"] as? [String: Any] {
                model = msg["model"] as? String ?? model
                if let u = msg["usage"] as? [String: Any] {
                    tokens += u["output_tokens"] as? Int ?? 0
                }
                if type == "assistant", let content = msg["content"] as? [[String: Any]] {
                    for block in content {
                        switch block["type"] as? String {
                        case "text":
                            if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { snippet = t }
                        case "tool_use":
                            if block["name"] as? String == "TodoWrite",
                               let input = block["input"] as? [String: Any],
                               let list = input["todos"] as? [[String: Any]] {
                                todos = list.enumerated().map { i, t in
                                    TodoItem(id: "\(i)", content: t["content"] as? String ?? "",
                                             status: t["status"] as? String ?? "pending")
                                }
                            }
                        default: break
                        }
                    }
                }
            }
        }
        guard sawRealTurn, let cwd else { return nil }
        let age = Date().timeIntervalSince(mtime)
        let state: SessionState = age < 20 ? .working : (age < 15 * 60 ? .idle : .finished)
        return AgentSession(
            id: file.lastPathComponent, sessionId: sessionId, kind: .claude,
            project: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd,
            branch: (branch?.isEmpty == false && branch != "HEAD") ? branch : nil,
            model: model, state: state, lastActivity: mtime,
            lastSnippet: String(snippet.prefix(200)), outputTokens: tokens,
            fileURL: file, todos: todos, attentionMessage: nil
        )
    }

    // MARK: Codex (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    private func scanCodex() -> [AgentSession] {
        guard fm.fileExists(atPath: codexSessions.path) else { return [] }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        guard let en = fm.enumerator(at: codexSessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [AgentSession] = []
        for case let file as URL in en where file.pathExtension == "jsonl" {
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime > cutoff else { continue }
            var cwd = ""
            var sessionId = file.deletingPathExtension().lastPathComponent
            if let lines = tailLines(of: file, maxBytes: 256 * 1024, fromHead: true) {
                for line in lines {
                    guard let d = jsonObject(line) else { continue }
                    if let payload = d["payload"] as? [String: Any] {
                        if let c = payload["cwd"] as? String { cwd = c }
                        if let sid = payload["id"] as? String { sessionId = sid }
                        if !cwd.isEmpty { break }
                    }
                }
            }
            let age = Date().timeIntervalSince(mtime)
            let state: SessionState = age < 20 ? .working : (age < 15 * 60 ? .idle : .finished)
            out.append(AgentSession(
                id: file.lastPathComponent, sessionId: sessionId, kind: .codex,
                project: cwd.isEmpty ? "codex" : URL(fileURLWithPath: cwd).lastPathComponent,
                cwd: cwd, branch: nil, model: nil, state: state, lastActivity: mtime,
                lastSnippet: "", outputTokens: 0, fileURL: file, todos: [], attentionMessage: nil
            ))
        }
        return out
    }

    // MARK: Transcript (on demand, for detail view)

    nonisolated static func transcript(for session: AgentSession) -> [TranscriptItem] {
        guard session.kind == .claude,
              let handle = try? FileHandle(forReadingFrom: session.fileURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(384 * 1024), size)
        try? handle.seek(toOffset: size - readSize)
        guard let data = try? handle.read(upToCount: Int(readSize)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items: [TranscriptItem] = []
        var lines = text.components(separatedBy: "\n")
        if size > readSize, !lines.isEmpty { lines.removeFirst() }
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let type = d["type"] as? String
            let ts = (d["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let uuid = d["uuid"] as? String ?? UUID().uuidString
            guard type == "user" || type == "assistant",
                  let msg = d["message"] as? [String: Any] else { continue }
            if type == "user" {
                if d["isSidechain"] as? Bool == true { continue }
                if let content = msg["content"] as? String {
                    let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, !t.hasPrefix("<") { // skip system-reminder wrappers
                        items.append(TranscriptItem(id: uuid, role: "you", text: String(t.prefix(500)), detail: nil, timestamp: ts))
                    }
                } else if let content = msg["content"] as? [[String: Any]] {
                    for block in content where block["type"] as? String == "text" {
                        let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty, !t.hasPrefix("<") {
                            items.append(TranscriptItem(id: uuid, role: "you", text: String(t.prefix(500)), detail: nil, timestamp: ts))
                        }
                    }
                }
            } else {
                guard let content = msg["content"] as? [[String: Any]] else { continue }
                for (bi, block) in content.enumerated() {
                    switch block["type"] as? String {
                    case "text":
                        let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty {
                            items.append(TranscriptItem(id: "\(uuid)-\(bi)", role: "agent", text: String(t.prefix(700)), detail: nil, timestamp: ts))
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        var detail = ""
                        if let input = block["input"] as? [String: Any] {
                            detail = (input["command"] as? String)
                                ?? (input["file_path"] as? String)
                                ?? (input["pattern"] as? String)
                                ?? (input["description"] as? String)
                                ?? (input["prompt"] as? String).map { String($0.prefix(80)) }
                                ?? ""
                        }
                        items.append(TranscriptItem(id: "\(uuid)-\(bi)", role: "tool", text: name, detail: detail.isEmpty ? nil : String(detail.prefix(160)), timestamp: ts))
                    default: break
                    }
                }
            }
        }
        return items.suffix(80).map { $0 }
    }

    // MARK: Helpers

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func tailLines(of file: URL, maxBytes: Int, fromHead: Bool = false) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(maxBytes), size)
        try? handle.seek(toOffset: fromHead ? 0 : size - readSize)
        guard let data = try? handle.read(upToCount: Int(readSize)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if !fromHead, size > readSize, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.isEmpty }
    }
}

func formatTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
    default: return "\(n)"
    }
}

func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
