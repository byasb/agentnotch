import Foundation

// MARK: - Storage scanner + safe cleaner
//
// Classification is intentionally conservative. Anything the app reads for live
// data, the user's agent history, or installed tools is NEVER offered for deletion.
// The SAFE set is limited to regenerable caches, temp, shell snapshots, and
// append-only logs (truncated, not removed). CAUTION items are reclaimable but
// have a real cost, so they are shown separately and never cleaned by "Clean safe".

enum CleanKind {
    case delete    // remove directory contents
    case truncate  // zero out a log file, keep it
}

enum CleanTier {
    case safe      // harmless, regenerable
    case caution   // reclaimable but loses something the user may want
    case never     // shown for transparency only, no action
}

struct StorageCategory: Identifiable {
    let id: String
    let title: String
    let detail: String
    let tier: CleanTier
    let kind: CleanKind
    let paths: [String]          // tilde paths; dir contents (delete) or files (truncate)
    var warning: String? = nil   // shown before a CAUTION action
    var bytes: Int64 = 0
    /// For CAUTION "old sessions": only files with mtime older than this are counted/removed.
    var olderThanDays: Int? = nil

    var expanded: [URL] {
        paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}

@MainActor
final class StorageManager: ObservableObject {
    @Published var categories: [StorageCategory] = []
    @Published var scanning = false
    @Published var lastFreed: Int64?

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Catalog with tiers verified by an adversarial safety pass. Deliberately
    /// conservative: nearly everything under ~/.claude and ~/.codex that looks like
    /// "cache" is actually user history, an auth/login record, or a snapshot a
    /// running session still depends on — so the auto-SAFE set is intentionally tiny.
    nonisolated static func catalog() -> [StorageCategory] {
        [
            // ---- SAFE: genuinely regenerable, no user data, no live-session dependency.
            StorageCategory(
                id: "cache", title: "Regenerable cache",
                detail: "Cached release notes and lookups Claude Code re-fetches on demand.",
                tier: .safe, kind: .delete,
                paths: ["~/.claude/cache"]),

            // ---- CAUTION: reclaimable, but each removes something real. Opt-in only.
            StorageCategory(
                id: "codex-images", title: "Codex generated images",
                detail: "Images Codex generated in past sessions.",
                tier: .caution, kind: .delete,
                paths: ["~/.codex/generated_images"],
                warning: "Permanently deletes generated images. This can't be undone."),
            StorageCategory(
                id: "codex-logdb", title: "Codex log database",
                detail: "Codex's local logs DB. Large, and open while Codex runs.",
                tier: .caution, kind: .delete,
                paths: ["~/.codex/logs_2.sqlite", "~/.codex/logs_2.sqlite-wal", "~/.codex/logs_2.sqlite-shm"],
                warning: "Quit Codex first — it holds this file open, so nothing frees until it exits, and deleting it mid-run can corrupt the log."),
            StorageCategory(
                id: "shell-snapshots", title: "Shell snapshots",
                detail: "Per-session shell environment snapshots.",
                tier: .caution, kind: .delete,
                paths: ["~/.claude/shell-snapshots", "~/.codex/shell_snapshots"],
                warning: "A running agent session keeps using the snapshot it launched with. Quit your active agents first, or their shell tools may break."),
            StorageCategory(
                id: "debug", title: "Debug logs",
                detail: "Diagnostic logs (live if debug logging is on).",
                tier: .caution, kind: .delete,
                paths: ["~/.claude/debug", "~/.codex/cache"],
                warning: "Turn off debug logging first if you have it on."),
            StorageCategory(
                id: "old-sessions", title: "Old session logs (90+ days)",
                detail: "Transcripts older than 90 days, across Claude Code and Codex.",
                tier: .caution, kind: .delete,
                paths: ["~/.claude/projects", "~/.codex/sessions"],
                warning: "This is your agent history. Removing it shrinks the All / 6M usage view and you can't browse those old sessions again.",
                olderThanDays: 90),
        ]
    }

    /// Read-only breakdown of the big space users, incl. things we never delete.
    nonisolated static func breakdown() -> [(String, [String])] {
        [
            ("Session history (never deleted here)", ["~/.claude/projects", "~/.codex/sessions"]),
            ("Installed plugins & tools (never deleted)", ["~/.claude/plugins", "~/.codex/plugins"]),
        ]
    }

    func scan() {
        scanning = true
        Task.detached(priority: .utility) {
            var cats = Self.catalog()
            for i in cats.indices {
                cats[i].bytes = Self.size(of: cats[i])
            }
            let result = cats
            await MainActor.run {
                self.categories = result
                self.scanning = false
            }
        }
    }

    nonisolated static func size(of cat: StorageCategory) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let cutoff = cat.olderThanDays.map { Date().addingTimeInterval(TimeInterval(-$0 * 86400)) }
        for url in cat.expanded {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                for case let f as URL in en {
                    guard let rv = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                    if let cutoff, let m = rv.contentModificationDate, m > cutoff { continue }
                    total += Int64(rv.fileSize ?? 0)
                }
            } else {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Clean one category. Returns bytes freed. Only ever touches paths in that
    /// category, respecting its olderThanDays filter. Truncate zeros logs in place.
    func clean(_ cat: StorageCategory) {
        Task.detached(priority: .utility) {
            let freed = Self.performClean(cat)
            await MainActor.run {
                self.lastFreed = freed
                self.scan()
            }
        }
    }

    /// Clean every SAFE category at once.
    func cleanAllSafe() {
        Task.detached(priority: .utility) {
            var freed: Int64 = 0
            for cat in Self.catalog() where cat.tier == .safe {
                freed += Self.performClean(cat)
            }
            let total = freed
            await MainActor.run {
                self.lastFreed = total
                self.scan()
            }
        }
    }

    nonisolated static func performClean(_ cat: StorageCategory) -> Int64 {
        let fm = FileManager.default
        let before = size(of: cat)
        let cutoff = cat.olderThanDays.map { Date().addingTimeInterval(TimeInterval(-$0 * 86400)) }
        for url in cat.expanded {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            switch cat.kind {
            case .truncate:
                // zero the file in place (keeps the inode the tool appends to)
                try? Data().write(to: url)
            case .delete:
                if isDir.boolValue {
                    guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                    for item in items {
                        if let cutoff {
                            // only remove entries whose newest content is older than cutoff
                            let newest = Self.newestMTime(item)
                            if newest > cutoff { continue }
                        }
                        try? fm.removeItem(at: item)
                    }
                } else {
                    try? fm.removeItem(at: url)
                }
            }
        }
        return max(0, before - size(of: cat))
    }

    private nonisolated static func newestMTime(_ url: URL) -> Date {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return .distantPast }
        if !isDir.boolValue {
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        var newest = Date.distantPast
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let f as URL in en {
                if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > newest {
                    newest = m
                }
            }
        }
        return newest
    }
}

func formatBytes(_ b: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(b), i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(b) B" : String(format: "%.1f %@", v, units[i])
}
