import Foundation

/// Passive, zero-CPU read-only reader for Claude Code, OpenAI Codex CLI, and Antigravity local quota caches.
/// Never polls remote APIs or spawns processes — auto-resets expired windows to Ready 0% and
/// attaches an honest age timestamp when cache files are older than 60m.
public enum QuotaReader {
    public static func readAll(home: URL) -> [QuotaItem] {
        var items: [QuotaItem] = []
        items.append(contentsOf: readClaudeQuotas(home: home))
        items.append(contentsOf: readCodexQuotas(home: home))
        items.append(contentsOf: readAntigravityQuotas(home: home))
        return items
    }

    public static func readCodexQuotas(home: URL) -> [QuotaItem] {
        let sessionsDir = RealHomeResolver.codexHomeDirectory.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir.path),
              let enumerator = fm.enumerator(
                  at: sessionsDir,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var latestURL: URL?
        var latestDate: Date = .distantPast
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let d = vals?.contentModificationDate ?? .distantPast
            if d > latestDate {
                latestDate = d
                latestURL = url
            }
        }
        guard let fileURL = latestURL, let fh = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let readStart = size > 32_768 ? (size - 32_768) : 0
        try? fh.seek(toOffset: readStart)
        guard let tailData = try? fh.readToEnd(),
              let text = String(data: tailData, encoding: .utf8) else { return [] }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }

            var out: [QuotaItem] = []
            if let primary = rl["primary"] as? [String: Any],
               let used = (primary["used_percent"] as? NSNumber)?.doubleValue {
                let reset = (primary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                out.append(QuotaItem(
                    id: "codex-5h",
                    label: "Codex 5h",
                    sublabel: "Session window",
                    provider: .codex,
                    usedFraction: used / 100.0,
                    resetsAt: reset,
                    fetchedAt: latestDate,
                    isAvailable: true
                ))
            }
            if let secondary = rl["secondary"] as? [String: Any],
               let used = (secondary["used_percent"] as? NSNumber)?.doubleValue {
                let reset = (secondary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                out.append(QuotaItem(
                    id: "codex-7d",
                    label: "Codex 7d",
                    sublabel: "Weekly window",
                    provider: .codex,
                    usedFraction: used / 100.0,
                    resetsAt: reset,
                    fetchedAt: latestDate,
                    isAvailable: true
                ))
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    public static func readClaudeQuotas(home: URL) -> [QuotaItem] {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            candidates.append(URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent(".claude.json"))
        }
        candidates.append(home.appendingPathComponent(".claude.json"))

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = json["cachedUsageUtilization"] as? [String: Any],
              let util = cached["utilization"] as? [String: Any] else {
            return []
        }

        let fetchedAt: Date? = {
            if let ms = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue, ms > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        }()

        var out: [QuotaItem] = []

        if let five = util["five_hour"] as? [String: Any] {
            let pct = (five["utilization"] as? NSNumber)?.doubleValue ?? 0
            let reset = (five["resets_at"] as? String).flatMap(LocalDateFormatting.parseISO8601)
            out.append(QuotaItem(
                id: "claude-5h",
                label: "Claude 5h",
                sublabel: "Session window",
                provider: .claude,
                usedFraction: pct / 100.0,
                resetsAt: reset,
                fetchedAt: fetchedAt,
                isAvailable: true
            ))
        }

        if let seven = util["seven_day"] as? [String: Any] {
            let pct = (seven["utilization"] as? NSNumber)?.doubleValue ?? 0
            let reset = (seven["resets_at"] as? String).flatMap(LocalDateFormatting.parseISO8601)
            out.append(QuotaItem(
                id: "claude-7d",
                label: "Claude 7d",
                sublabel: "Weekly window",
                provider: .claude,
                usedFraction: pct / 100.0,
                resetsAt: reset,
                fetchedAt: fetchedAt,
                isAvailable: true
            ))
        }

        return out
    }

    public static func readAntigravityQuotas(home: URL) -> [QuotaItem] {
        let fm = FileManager.default
        var cacheFiles: [(url: URL, id: String, label: String)] = []
        var seenPaths = Set<String>()

        func appendCaches(in directory: URL, fallbackId: String, fallbackLabel: String) {
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            let matches = entries
                .filter { $0.lastPathComponent.hasPrefix(".quota_cache") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for url in matches {
                let stdPath = url.standardizedFileURL.path
                guard seenPaths.insert(stdPath).inserted else { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                let suffix = stem
                    .replacingOccurrences(of: ".quota_cache_", with: "")
                    .replacingOccurrences(of: ".quota_cache", with: "")
                let itemId = suffix.isEmpty ? fallbackId : "agy-\(suffix.lowercased())"
                let itemLabel = suffix.isEmpty ? fallbackLabel : "Antigravity · \(suffix.uppercased())"
                cacheFiles.append((url: url, id: itemId, label: itemLabel))
            }
        }

        // 1. Standard single-profile directory
        appendCaches(
            in: home.appendingPathComponent(".gemini/antigravity", isDirectory: true),
            fallbackId: "agy-default",
            fallbackLabel: "Antigravity"
        )

        // 2. Multi-profile root & sorted Profile* directories
        let profilesDir = home.appendingPathComponent("AntigravityProfiles", isDirectory: true)
        appendCaches(in: profilesDir, fallbackId: "agy-profile", fallbackLabel: "Antigravity")

        if let profileEntries = try? fm.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil) {
            let sortedProfiles = profileEntries
                .filter { $0.lastPathComponent.hasPrefix("Profile") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for prof in sortedProfiles {
                let pname = prof.lastPathComponent
                let fid = "agy-\(pname.lowercased())"
                let flabel = "Antigravity · \(pname)"
                appendCaches(in: prof, fallbackId: fid, fallbackLabel: flabel)
                appendCaches(
                    in: prof.appendingPathComponent("home/.gemini/antigravity", isDirectory: true),
                    fallbackId: fid,
                    fallbackLabel: flabel
                )
            }
        }

        var out: [QuotaItem] = []
        for entry in cacheFiles {
            guard let data = try? Data(contentsOf: entry.url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let tier = (json["tier"] as? String) ?? "Standard"
            let updated: Date? = {
                if let ts = (json["updated"] as? NSNumber)?.doubleValue, ts > 1_600_000_000 {
                    return Date(timeIntervalSince1970: ts)
                }
                return (try? fm.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date)
            }()

            // In .quota_cache*.json, g5_pct / gw_pct / c5_pct represent REMAINING percent (100 = full remaining)
            let g5Rem = (json["g5_pct"] as? NSNumber)?.doubleValue ?? 100
            let gwRem = (json["gw_pct"] as? NSNumber)?.doubleValue ?? 100
            let g5Time = (json["g5_time"] as? NSNumber)?.doubleValue
            let gwTime = (json["gw_time"] as? NSNumber)?.doubleValue

            let used5h = max(0, min(1, (100.0 - g5Rem) / 100.0))
            let usedWk = max(0, min(1, (100.0 - gwRem) / 100.0))

            let primaryUsed = max(used5h, usedWk)
            let resetDate: Date? = {
                if used5h >= usedWk, let t = g5Time, t > 1_600_000_000 { return Date(timeIntervalSince1970: t) }
                if let t = gwTime, t > 1_600_000_000 { return Date(timeIntervalSince1970: t) }
                return nil
            }()

            out.append(QuotaItem(
                id: entry.id,
                label: entry.label,
                sublabel: "\(tier) · Gemini \(Int(g5Rem))% 5h / \(Int(gwRem))% wk",
                provider: .antigravity,
                usedFraction: primaryUsed,
                resetsAt: resetDate,
                fetchedAt: updated,
                isAvailable: true
            ))
        }

        return out
    }
}
