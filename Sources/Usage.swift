import Foundation

// MARK: - Usage range

enum UsageRange: String, CaseIterable, Sendable {
    case d7 = "7D"
    case d30 = "30D"
    case m6 = "6M"
    case all = "All"

    var seconds: TimeInterval? {
        switch self {
        case .d7: 7 * 86400
        case .d30: 30 * 86400
        case .m6: 182 * 86400
        case .all: nil
        }
    }
}

// MARK: - Models

struct ScanProgress: Equatable {
    var done = 0
    var total = 0
    var active = false
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

struct UsageEntry {
    let ts: Date
    let model: String
    let agent: AgentKind
    let input, output, cacheR, cacheW: Int
}

struct Bucket: Identifiable {
    let id: String     // sort key
    let label: String  // axis label
    let date: Date
    var tokens: Int
}

struct LimitWindow {
    let pct: Double
    let resets: Date
    let minutes: Int
    var label: String {
        switch minutes {
        case ..<600: "5h"
        case ..<20000: "7d"
        default: "\(minutes / 1440)d"
        }
    }
}

struct CodexLimits {
    let windows: [LimitWindow]
    let plan: String
    let reportedAt: Date
}

struct UsageStats {
    var s5h = UsageSummary()
    var s24h = UsageSummary()
    var buckets: [Bucket] = []          // oldest→newest, granularity depends on range
    var hourGrid: [[Int]] = []          // 7d range only: [day][hour] output tokens
    var heatmapDays: [Bucket] = []      // row labels for hourGrid
    var models: [(name: String, output: Int)] = []
    var total = 0                        // in+out for selected range
    var claudeTokens = 0
    var codexTokens = 0
    var requests = 0
    var estCost = 0.0
    var codexLimits: CodexLimits?
    var range: UsageRange = .d7
}

// MARK: - Engine

final class UsageEngine: @unchecked Sendable {
    static let shared = UsageEngine()
    private struct FileAgg { let mtime: Date; let size: UInt64; let entries: [UsageEntry] }
    private var cache: [String: FileAgg] = [:]
    private let lock = NSLock()

    /// Rough public per-MTok pricing by model family. Estimate only.
    static func price(for model: String) -> (input: Double, output: Double) {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("opus") { return (15, 75) }
        if m.contains("haiku") { return (1, 5) }
        if m.contains("gpt") || m.contains("codex") { return (1.25, 10) }
        return (3, 15) // sonnet & default
    }

    func compute(claudeDir: URL, codexDir: URL, range: UsageRange,
                 progress: (@Sendable (Int, Int) -> Void)? = nil) -> UsageStats {
        let now = Date()
        let cutoff = range.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast

        // Pass 1 — collect the worklist (cheap: dir listing + mtime filter, no reads).
        // This gives us an accurate denominator so the loader shows real progress.
        let claudeFiles = candidateFiles(in: claudeDir, cutoff: cutoff, recursive: false)
        let codexFiles = candidateFiles(in: codexDir, cutoff: cutoff, recursive: true)
        let total = claudeFiles.count + codexFiles.count
        progress?(0, total)

        // Pass 2 — read/parse (cached per file), ticking progress as we go.
        var entries: [UsageEntry] = []
        var done = 0
        let tick: (Int) -> Void = { n in
            done += n
            if done % 25 == 0 || done == total { progress?(done, total) }
        }
        for (file, mtime, size) in claudeFiles {
            entries += cached(file: file, mtime: mtime, size: size) { Self.parseClaude(file: file) }
            tick(1)
        }
        let (codexEntries, limits) = scanCodex(files: codexFiles, codexDir: codexDir, tick: tick)
        entries += codexEntries
        progress?(total, total)

        // mtime admits the file; the entry's own timestamp decides the window
        // (Codex rewrites old rollout files, so mtime alone over-includes)
        entries = entries.filter { $0.ts > cutoff }
        var stats = Self.aggregate(entries: entries, now: now, range: range)
        stats.codexLimits = limits
        return stats
    }

    /// Candidate .jsonl files within the window, as (url, mtime, size). No file reads.
    private func candidateFiles(in dir: URL, cutoff: Date, recursive: Bool) -> [(URL, Date, UInt64)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var out: [(URL, Date, UInt64)] = []
        func admit(_ file: URL) {
            guard file.pathExtension == "jsonl",
                  let rv = try? file.resourceValues(forKeys: Set(keys)),
                  let mtime = rv.contentModificationDate, mtime > cutoff else { return }
            out.append((file, mtime, UInt64(rv.fileSize ?? 0)))
        }
        if recursive {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else { return out }
            for case let file as URL in en { admit(file) }
        } else {
            guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return out }
            for sub in subs {
                guard let files = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: keys) else { continue }
                for file in files { admit(file) }
            }
        }
        return out
    }

    // MARK: Claude

    private static func parseClaude(file: URL) -> [UsageEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [UsageEntry] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard line.contains("\"usage\""),
                  let data = line.data(using: .utf8),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  d["type"] as? String == "assistant",
                  let ts = (d["timestamp"] as? String).flatMap({ iso.date(from: $0) }),
                  let msg = d["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any] else { continue }
            if let rid = d["requestId"] as? String, !seen.insert(rid).inserted { continue }
            out.append(UsageEntry(
                ts: ts,
                model: msg["model"] as? String ?? "unknown",
                agent: .claude,
                input: u["input_tokens"] as? Int ?? 0,
                output: u["output_tokens"] as? Int ?? 0,
                cacheR: u["cache_read_input_tokens"] as? Int ?? 0,
                cacheW: u["cache_creation_input_tokens"] as? Int ?? 0
            ))
        }
        return out
    }

    // MARK: Codex — cumulative token_count per rollout; one entry per session file

    private func scanCodex(files: [(URL, Date, UInt64)], codexDir: URL,
                           tick: (Int) -> Void) -> ([UsageEntry], CodexLimits?) {
        var out: [UsageEntry] = []
        for (file, mtime, size) in files {
            out += cached(file: file, mtime: mtime, size: size) { Self.parseCodex(file: file) }
            tick(1)
        }
        // limits: newest file (last 30d, independent of the selected range) whose tail
        // has a rate_limits report. Enumerate cheaply — this is metadata-only.
        let limitsCutoff = Date().addingTimeInterval(-30 * 86400)
        var candidates = files.filter { $0.1 > limitsCutoff }.map { ($0.0, $0.1) }
        if candidates.isEmpty {
            // selected range shorter than 30d: look wider just for the limits report
            candidates = candidateFiles(in: codexDir, cutoff: limitsCutoff, recursive: true).map { ($0.0, $0.1) }
        }
        var limits: CodexLimits?
        for (file, mtime) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(50) {
            if let l = Self.codexLimits(file: file, reportedAt: mtime) { limits = l; break }
        }
        return (out, limits)
    }

    /// One entry per session: last cumulative total_token_usage.
    private static func parseCodex(file: URL) -> [UsageEntry] {
        guard let line = lastLine(of: file, containing: "\"token_count\""),
              let data = line.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = d["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = (d["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date.distantPast
        let input = total["input_tokens"] as? Int ?? 0
        let cached = total["cached_input_tokens"] as? Int ?? 0
        return [UsageEntry(
            ts: ts, model: "codex", agent: .codex,
            input: max(0, input - cached),
            output: total["output_tokens"] as? Int ?? 0,
            cacheR: cached, cacheW: 0
        )]
    }

    private static func codexLimits(file: URL, reportedAt: Date) -> CodexLimits? {
        guard let line = lastLine(of: file, containing: "\"rate_limits\""),
              let data = line.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = d["payload"] as? [String: Any],
              let rl = payload["rate_limits"] as? [String: Any] else { return nil }
        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any], let pct = w["used_percent"] as? Double else { continue }
            windows.append(LimitWindow(
                pct: pct,
                resets: Date(timeIntervalSince1970: w["resets_at"] as? Double ?? 0),
                minutes: w["window_minutes"] as? Int ?? 0
            ))
        }
        guard !windows.isEmpty else { return nil }
        return CodexLimits(windows: windows, plan: rl["plan_type"] as? String ?? "", reportedAt: reportedAt)
    }

    private static func lastLine(of file: URL, containing needle: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(512 * 1024), size)
        try? handle.seek(toOffset: size - readSize)
        guard let data = try? handle.read(upToCount: Int(readSize)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last { $0.contains(needle) }.map(String.init)
    }

    // MARK: Cache

    private func cached(file: URL, mtime: Date, size: UInt64, parse: () -> [UsageEntry]) -> [UsageEntry] {
        let key = file.path
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit, hit.mtime == mtime, hit.size == size { return hit.entries }
        let entries = parse()
        lock.lock()
        cache[key] = FileAgg(mtime: mtime, size: size, entries: entries)
        lock.unlock()
        return entries
    }

    // MARK: Aggregate

    private static func aggregate(entries: [UsageEntry], now: Date, range: UsageRange) -> UsageStats {
        var stats = UsageStats()
        stats.range = range
        let cal = Calendar.current
        let c5h = now.addingTimeInterval(-5 * 3600)
        let c24h = now.addingTimeInterval(-24 * 3600)

        // bucket configuration
        enum Gran { case day(Int), week, month }
        let gran: Gran
        switch range {
        case .d7: gran = .day(7)
        case .d30: gran = .day(30)
        case .m6: gran = .week
        case .all: gran = .month
        }
        let df = DateFormatter()
        var bucketIndex: [String: Int] = [:]

        func bucketKey(_ date: Date) -> (key: String, label: String, start: Date) {
            switch gran {
            case .day:
                df.dateFormat = "yyyy-MM-dd"
                let start = cal.startOfDay(for: date)
                return (df.string(from: start), start.formatted(.dateTime.day()), start)
            case .week:
                let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
                df.dateFormat = "yyyy-MM-dd"
                return ("w" + df.string(from: start), start.formatted(.dateTime.day().month(.abbreviated)), start)
            case .month:
                let start = cal.dateInterval(of: .month, for: date)?.start ?? date
                df.dateFormat = "yyyy-MM"
                return (df.string(from: start), start.formatted(.dateTime.month(.abbreviated)), start)
            }
        }

        // pre-create buckets for fixed-day ranges so empty days render
        if case .day(let n) = gran {
            for offset in stride(from: n - 1, through: 0, by: -1) {
                let d = cal.startOfDay(for: now.addingTimeInterval(TimeInterval(-offset * 86400)))
                let (key, label, start) = bucketKey(d)
                bucketIndex[key] = stats.buckets.count
                stats.buckets.append(Bucket(id: key, label: label, date: start, tokens: 0))
            }
        }
        if range == .d7 {
            stats.hourGrid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        }

        var modelTotals: [String: Int] = [:]
        for e in entries {
            let work = e.input + e.output
            stats.total += work
            stats.requests += 1
            if e.agent == .claude { stats.claudeTokens += work } else { stats.codexTokens += work }
            let p = price(for: e.model)
            stats.estCost += Double(e.input) * p.input / 1e6
                + Double(e.output) * p.output / 1e6
                + Double(e.cacheR) * p.input * 0.1 / 1e6
                + Double(e.cacheW) * p.input * 1.25 / 1e6
            modelTotals[e.model, default: 0] += e.output

            let (key, label, start) = bucketKey(e.ts)
            if let idx = bucketIndex[key] {
                stats.buckets[idx].tokens += work
            } else if e.ts > .distantPast {
                bucketIndex[key] = stats.buckets.count
                stats.buckets.append(Bucket(id: key, label: label, date: start, tokens: work))
            }
            if range == .d7, let idx = bucketIndex.firstDayIndex(for: e.ts, cal: cal, now: now) {
                stats.hourGrid[idx][cal.component(.hour, from: e.ts)] += e.output
            }
            func add(_ s: inout UsageSummary) {
                s.inputTokens += e.input; s.outputTokens += e.output
                s.cacheReadTokens += e.cacheR; s.cacheCreateTokens += e.cacheW
                s.requests += 1
            }
            if e.ts > c5h { add(&stats.s5h) }
            if e.ts > c24h { add(&stats.s24h) }
        }
        stats.buckets.sort { $0.date < $1.date }
        if range == .d7 { stats.heatmapDays = stats.buckets }
        stats.models = modelTotals.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return stats
    }
}

private extension [String: Int] {
    /// Index 0..6 for a date within the last 7 days (0 = 6 days ago), else nil.
    func firstDayIndex(for date: Date, cal: Calendar, now: Date) -> Int? {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 99
        guard (0...6).contains(days) else { return nil }
        return 6 - days
    }
}

// MARK: - System stats (CPU / RAM) for the stats tiles

@MainActor
final class SystemStats: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var memUsedGB: Double = 0
    let memTotalGB: Double
    private var timer: Timer?

    init() {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        memTotalGB = Double(size) / 1_073_741_824
    }

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        Task.detached(priority: .utility) {
            guard let out = ServerMonitor.run("/usr/bin/top", ["-l", "1", "-n", "0", "-stats", "pid"]) else { return }
            var cpu = 0.0, used = 0.0
            for line in out.split(separator: "\n") {
                if line.hasPrefix("CPU usage:") {
                    if let idleStr = line.split(separator: ",").last?
                        .replacingOccurrences(of: "% idle", with: "")
                        .trimmingCharacters(in: .whitespaces),
                       let idle = Double(idleStr) {
                        cpu = max(0, 100 - idle)
                    }
                } else if line.hasPrefix("PhysMem:") {
                    let parts = line.split(separator: " ")
                    if parts.count > 1 {
                        let v = parts[1]
                        if v.hasSuffix("G"), let g = Double(v.dropLast()) { used = g }
                        else if v.hasSuffix("M"), let m = Double(v.dropLast()) { used = m / 1024 }
                    }
                }
            }
            let c = cpu, u = used
            await MainActor.run {
                self.cpuPercent = c
                self.memUsedGB = u
            }
        }
    }
}

func formatCost(_ d: Double) -> String {
    d >= 100 ? String(format: "$%.0f", d) : String(format: "$%.2f", d)
}
