import Foundation
import AppKit

// MARK: - Dev servers (listening TCP ports 3000-9999)

struct DevServer: Identifiable {
    let id: Int32       // pid
    let port: Int
    let command: String
    let project: String
    let framework: String?
    let startedAt: Date?
    var url: String { "http://localhost:\(port)" }
}

@MainActor
final class ServerMonitor: ObservableObject {
    @Published var servers: [DevServer] = []
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run { self.servers = found }
        }
    }

    nonisolated static func scan() -> [DevServer] {
        guard let out = run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn"]) else { return [] }
        var pid: Int32 = 0, cmd = ""
        var byPid: [Int32: (cmd: String, ports: Set<Int>)] = [:]
        for line in out.split(separator: "\n") {
            guard let first = line.first else { continue }
            let rest = String(line.dropFirst())
            switch first {
            case "p": pid = Int32(rest) ?? 0
            case "c": cmd = rest
            case "n":
                if let portStr = rest.split(separator: ":").last, let port = Int(portStr),
                   (3000...9999).contains(port) {
                    byPid[pid, default: (cmd, [])].ports.insert(port)
                    byPid[pid]?.cmd = cmd
                }
            default: break
            }
        }
        var result: [DevServer] = []
        for (pid, info) in byPid {
            // skip our own agents' MCP etc: keep node/python/ruby-ish dev processes, skip system
            let lower = info.cmd.lowercased()
            if ["rapportd", "sharingd", "controlce", "airplay"].contains(where: { lower.contains($0) }) { continue }
            let full = run("/bin/ps", ["-o", "command=,lstart=", "-p", "\(pid)"]) ?? info.cmd
            let cwd = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-F", "n"])?
                .split(separator: "\n").last(where: { $0.hasPrefix("n") }).map { String($0.dropFirst()) } ?? ""
            let project = cwd.isEmpty ? info.cmd : URL(fileURLWithPath: cwd).lastPathComponent
            let framework = detectFramework(command: full, cwd: cwd)
            for port in info.ports.sorted() {
                result.append(DevServer(id: pid, port: port, command: info.cmd,
                                        project: project, framework: framework, startedAt: nil))
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    nonisolated static func detectFramework(command: String, cwd: String) -> String? {
        let c = command.lowercased()
        for (needle, name) in [("next", "Next.js"), ("vite", "Vite"), ("astro", "Astro"),
                               ("wrangler", "Wrangler"), ("storybook", "Storybook"),
                               ("webpack", "Webpack"), ("flask", "Flask"), ("uvicorn", "FastAPI"),
                               ("rails", "Rails"), ("php", "PHP"), ("http.server", "Python http"),
                               ("expo", "Expo"), ("node", "Node")] {
            if c.contains(needle) { return name }
        }
        return nil
    }

    func stop(_ server: DevServer) {
        kill(server.id, SIGTERM)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            refresh()
        }
    }

    nonisolated static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Fast Actions (saved shell commands)

struct FastAction: Identifiable, Codable {
    var id = UUID()
    var name: String
    var command: String
}

@MainActor
final class ActionStore: ObservableObject {
    @Published var actions: [FastAction] = []
    @Published var running: [UUID: Process] = [:]
    private var file: URL {
        EventCenter.shared.dir.appendingPathComponent("actions.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([FastAction].self, from: data) else { return }
        actions = list
    }

    func save() {
        try? FileManager.default.createDirectory(at: EventCenter.shared.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(actions) { try? data.write(to: file) }
    }

    func add(name: String, command: String) {
        actions.append(FastAction(name: name, command: command))
        save()
    }

    func remove(_ action: FastAction) {
        stop(action)
        actions.removeAll { $0.id == action.id }
        save()
    }

    func run(_ action: FastAction) {
        stop(action)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", action.command]
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.running[action.id] = nil }
        }
        try? p.run()
        running[action.id] = p
    }

    func stop(_ action: FastAction) {
        running[action.id]?.terminate()
        running[action.id] = nil
    }
}

// MARK: - Quick Routes (agent folders and files)

struct Route: Identifiable {
    var id: String { agent + label }
    let agent: String
    let label: String
    let path: String
    let isFile: Bool
    var exists: Bool { FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) }
}

enum Routes {
    static func all() -> [Route] {
        let candidates: [Route] = [
            Route(agent: "Claude", label: "Skills", path: "~/.claude/skills", isFile: false),
            Route(agent: "Claude", label: "Plugins", path: "~/.claude/plugins", isFile: false),
            Route(agent: "Claude", label: "Commands", path: "~/.claude/commands", isFile: false),
            Route(agent: "Claude", label: "Hooks", path: "~/.claude/hooks", isFile: false),
            Route(agent: "Claude", label: "Settings", path: "~/.claude/settings.json", isFile: true),
            Route(agent: "Claude", label: "Sessions", path: "~/.claude/projects", isFile: false),
            Route(agent: "Claude", label: "CLAUDE.md", path: "~/.claude/CLAUDE.md", isFile: true),
            Route(agent: "Claude", label: "Logs", path: "~/Library/Logs/Claude", isFile: false),
            Route(agent: "Codex", label: "Config", path: "~/.codex/config.toml", isFile: true),
            Route(agent: "Codex", label: "Sessions", path: "~/.codex/sessions", isFile: false),
            Route(agent: "Codex", label: "AGENTS.md", path: "~/.codex/AGENTS.md", isFile: true),
            Route(agent: "Codex", label: "Root", path: "~/.codex", isFile: false),
        ]
        return candidates.filter(\.exists)
    }

    static func open(_ route: Route) {
        let path = (route.path as NSString).expandingTildeInPath
        if route.isFile {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }
}
