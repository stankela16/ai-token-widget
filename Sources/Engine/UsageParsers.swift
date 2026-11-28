import Foundation
import SQLite3

public enum RealHomeResolver {
    /// Resolves the actual macOS user home directory (`/Users/<name>`), even if launched inside a profiled HOME env.
    public static var homeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Honors `CLAUDE_CONFIG_DIR` when set, otherwise falls back to `~/.claude`.
    public static var claudeConfigDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Honors `CODEX_HOME` when set, otherwise falls back to `~/.codex`.
    public static var codexHomeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }
}

public enum ProjectNormalizer {
    public static func fromDirectoryPath(_ cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        return normalize(last)
    }

    public static func fromClaudeFolderName(_ folder: String) -> String {
        // Folder looks like `-Users-alice-Developer-milkit`
        let markers = ["-Developer-", "-Desktop-Projects-", "-Projects-", "-Code-", "-workspace-", "-repos-", "-src-"]
        for m in markers {
            if let range = folder.range(of: m) {
                let tail = String(folder[range.upperBound...])
                if !tail.isEmpty {
                    return normalize(tail)
                }
            }
        }
        let cleaned = folder.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalize(cleaned.split(separator: "-").last.map(String.init) ?? "general")
    }

    public static func fromWorkspaceURIJSON(_ raw: String) -> String? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
              let first = arr.first else {
            return nil
        }
        let urlString = first.removingPercentEncoding ?? first
        if let url = URL(string: urlString), !url.lastPathComponent.isEmpty {
            return normalize(url.lastPathComponent)
        }
        let last = urlString.split(separator: "/").last.map(String.init)
        return last.map(normalize)
    }

    public static func normalize(_ name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return "general" }
        return lower
    }
}

/// Safe 3-branch read-only SQLite opener (never writes or creates -wal/-shm next to foreign DBs).
public enum SafeReadOnlySQLite {
    public static func withConnection<T>(to dbPath: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let shmExists = fm.fileExists(atPath: dbPath + "-shm")
        let walPath = dbPath + "-wal"
        let walSize = (try? fm.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0

        var tempDir: URL?
        let uri: String

        if shmExists {
            // Active WAL: read directly in read-only mode
            uri = "file:\(percentEncodePath(dbPath))?mode=ro"
        } else if walSize == 0 {
            // Clean cold DB: immutable read-only (<1 ms, zero lock/copy)
            uri = "file:\(percentEncodePath(dbPath))?mode=ro&immutable=1"
        } else {
            // Orphan non-empty -wal without -shm: read via short-lived temp copy
            let tmp = fm.temporaryDirectory.appendingPathComponent("milkit-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let dstDB = tmp.appendingPathComponent("db.sqlite")
            try fm.copyItem(atPath: dbPath, toPath: dstDB.path)
            if fm.fileExists(atPath: walPath) {
                try? fm.copyItem(atPath: walPath, toPath: dstDB.path + "-wal")
            }
            tempDir = tmp
            uri = "file:\(percentEncodePath(dstDB.path))?mode=ro"
        }

        defer {
            if let tempDir { try? fm.removeItem(at: tempDir) }
        }

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "SafeReadOnlySQLite", code: Int(rc))
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        return try body(handle)
    }

    private static func percentEncodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}

public enum LocalDateFormatting {
    public static func dayAndHour(from date: Date) -> (day: String, hour: Int) {
        var t = time_t(date.timeIntervalSince1970)
        var local = tm()
        localtime_r(&t, &local)
        let y = Int(local.tm_year) + 1900
        let m = Int(local.tm_mon) + 1
        let d = Int(local.tm_mday)
        let h = Int(local.tm_hour)
        // Fast ASCII YYYY-MM-DD without String(format:) overhead
        let dayStr = "\(y)-\(m < 10 ? "0" : "")\(m)-\(d < 10 ? "0" : "")\(d)"
        return (dayStr, h)
    }

    /// Zero-allocation fast ISO-8601 parser (`YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`), ~10,000x faster than allocating `ISO8601DateFormatter`.
    public static func parseISO8601(_ str: String) -> Date? {
        let bytes = Array(str.utf8)
        guard bytes.count >= 20,
              bytes[4] == 0x2D, bytes[7] == 0x2D,
              (bytes[10] == 0x54 || bytes[10] == 0x20),
              bytes[13] == 0x3A, bytes[16] == 0x3A else {
            return fallbackParseISO8601(str)
        }

        @inline(__always)
        func digits(_ start: Int, _ len: Int) -> Int? {
            var v = 0
            for i in start..<(start + len) {
                let c = bytes[i]
                guard c >= 0x30 && c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }

        guard let year = digits(0, 4),
              let month = digits(5, 2),
              let day = digits(8, 2),
              let hour = digits(11, 2),
              let minute = digits(14, 2),
              let second = digits(17, 2) else {
            return fallbackParseISO8601(str)
        }

        var idx = 19
        var fracSeconds = 0.0
        if idx < bytes.count && bytes[idx] == 0x2E { // '.'
            idx += 1
            var scale = 0.1
            while idx < bytes.count && bytes[idx] >= 0x30 && bytes[idx] <= 0x39 {
                fracSeconds += Double(bytes[idx] - 0x30) * scale
                scale *= 0.1
                idx += 1
            }
        }

        var tzOffsetSeconds = 0
        if idx < bytes.count {
            let tz = bytes[idx]
            if tz == 0x5A || tz == 0x7A { // 'Z' or 'z'
                tzOffsetSeconds = 0
            } else if (tz == 0x2B || tz == 0x2D), idx + 5 < bytes.count { // '+' or '-'
                let sign = (tz == 0x2B) ? 1 : -1
                if let tzH = digits(idx + 1, 2) {
                    let minStart = (bytes[idx + 3] == 0x3A) ? idx + 4 : idx + 3
                    if minStart + 2 <= bytes.count, let tzM = digits(minStart, 2) {
                        tzOffsetSeconds = sign * (tzH * 3600 + tzM * 60)
                    } else {
                        return fallbackParseISO8601(str)
                    }
                } else {
                    return fallbackParseISO8601(str)
                }
            } else {
                return fallbackParseISO8601(str)
            }
        }

        var t = tm()
        t.tm_year = Int32(year - 1900)
        t.tm_mon = Int32(month - 1)
        t.tm_mday = Int32(day)
        t.tm_hour = Int32(hour)
        t.tm_min = Int32(minute)
        t.tm_sec = Int32(second)
        let utcSec = timegm(&t)
        return Date(timeIntervalSince1970: Double(utcSec - tzOffsetSeconds) + fracSeconds)
    }

    private static func fallbackParseISO8601(_ str: String) -> Date? {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: str) { return d }
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        return isoBasic.date(from: str)
    }
}

/// Reads `conversation_summaries.db` across all Antigravity profiles to map conversation UUID -> project name.
public enum AntigravityProjectMapLoader {
    public static func loadMap(home: URL) -> [String: String] {
        var map: [String: String] = [:]
        let fm = FileManager.default
        var summaryPaths: [String] = []

        let profilesRoot = home.appendingPathComponent("AntigravityProfiles")
        if let profiles = try? fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: nil) {
            for p in profiles {
                for sub in ["home/.gemini/antigravity", "home/.gemini/antigravity-ide", "home/.gemini/antigravity-cli"] {
                    let cand = p.appendingPathComponent(sub).appendingPathComponent("conversation_summaries.db").path
                    if fm.fileExists(atPath: cand) { summaryPaths.append(cand) }
                }
            }
        }
        for sub in [".gemini/antigravity", ".gemini/antigravity-ide", ".gemini/antigravity-cli"] {
            let cand = home.appendingPathComponent(sub).appendingPathComponent("conversation_summaries.db").path
            if fm.fileExists(atPath: cand) { summaryPaths.append(cand) }
        }

        for path in summaryPaths {
            try? SafeReadOnlySQLite.withConnection(to: path) { db in
                var stmt: OpaquePointer?
                let sql = "SELECT conversation_id, workspace_uris FROM conversation_summaries WHERE workspace_uris != ''"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
                defer { sqlite3_finalize(s) }
                while sqlite3_step(s) == SQLITE_ROW {
                    guard let cId = sqlite3_column_text(s, 0), let cUri = sqlite3_column_text(s, 1) else { continue }
                    let convId = String(cString: cId)
                    let uriJson = String(cString: cUri)
                    if let proj = ProjectNormalizer.fromWorkspaceURIJSON(uriJson) {
                        map[convId] = proj
                    }
                }
            }
        }
        return map
    }
}

/// Incremental streaming byte-offset parser for Claude Code `~/.claude/projects/**/*.jsonl`.
/// Uses C `getline` + `memmem` raw byte pre-filter + pure-Swift `JSONDecoder` for ~2 MB peak RAM
/// even on 80+ MB session files containing base64 tool outputs.
public enum ClaudeJSONLParser {
    private struct ClaudeLineDTO: Decodable {
        struct MessageDTO: Decodable {
            struct UsageDTO: Decodable {
                struct CacheCreationDTO: Decodable {
                    let ephemeral_5m_input_tokens: Int64?
                    let ephemeral_1h_input_tokens: Int64?
                }
                let input_tokens: Int64?
                let output_tokens: Int64?
                let cache_read_input_tokens: Int64?
                let cache_creation_input_tokens: Int64?
                let cache_creation: CacheCreationDTO?
            }
            let id: String?
            let model: String?
            let usage: UsageDTO?
        }
        let type: String?
        let requestId: String?
        let sessionId: String?
        let cwd: String?
        let timestamp: String?
        let message: MessageDTO?
    }

    private static let needleUsage: [UInt8] = Array("\"usage\"".utf8)
    private static let needleAssistant: [UInt8] = Array("\"assistant\"".utf8)

    public static func parseIncremental(
        fileURL: URL,
        existingCursor: FileCursor?
    ) -> (records: [UsageRecord], cursor: FileCursor)? {
        let path = fileURL.path
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }

        let fileSize = Int64(st.st_size)
        let inode = Int64(st.st_ino)
        let mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))

        var startOffset: Int64 = 0
        if let cur = existingCursor {
            if cur.inode == inode && cur.byteOffset == fileSize && cur.mtimeNs == mtimeNs {
                return nil // Unchanged
            }
            if cur.inode == inode && cur.byteOffset <= fileSize {
                startOffset = cur.byteOffset
            }
        }

        guard let fp = fopen(path, "rb") else { return nil }
        defer { fclose(fp) }
        if startOffset > 0 {
            guard fseeko(fp, off_t(startOffset), SEEK_SET) == 0 else { return nil }
        }

        // Resolve parent project folder & session stem cleanly even for nested
        // `~/.claude/projects/<project>/<session-uuid>/subagents/agent-*.jsonl` files!
        let parentDir = fileURL.deletingLastPathComponent()
        let isSubagent = parentDir.lastPathComponent == "subagents"
        let projectDirName: String
        let fallbackSessionStem: String
        if isSubagent {
            let sessionDir = parentDir.deletingLastPathComponent()
            projectDirName = sessionDir.deletingLastPathComponent().lastPathComponent
            fallbackSessionStem = sessionDir.lastPathComponent
        } else {
            projectDirName = parentDir.lastPathComponent
            fallbackSessionStem = fileURL.deletingPathExtension().lastPathComponent
        }
        let folderProject = ProjectNormalizer.fromClaudeFolderName(projectDirName)
        let decoder = JSONDecoder()

        var records: [UsageRecord] = []
        var consumedOffset = startOffset
        var lineBuf: UnsafeMutablePointer<CChar>?
        var lineCap: Int = 0
        defer {
            if let lineBuf { free(lineBuf) }
        }

        while true {
            let readLen = getline(&lineBuf, &lineCap, fp)
            if readLen <= 0 { break }
            guard let buf = lineBuf else { break }

            // Only advance cursor over complete newline-terminated lines so partial writes retry cleanly
            guard buf[readLen - 1] == 0x0A else { break }
            consumedOffset += Int64(readLen)

            // Ultra-fast C memmem byte scan: skips >90% of JSONL volume (user prompts, base64 images, tool results)
            let hasUsage = needleUsage.withUnsafeBytes { nPtr in
                memmem(buf, readLen, nPtr.baseAddress, nPtr.count) != nil
            }
            guard hasUsage else { continue }

            let hasAssistant = needleAssistant.withUnsafeBytes { nPtr in
                memmem(buf, readLen, nPtr.baseAddress, nPtr.count) != nil
            }
            guard hasAssistant else { continue }

            let lineData = Data(bytesNoCopy: buf, count: readLen, deallocator: .none)
            guard let dto = try? decoder.decode(ClaudeLineDTO.self, from: lineData),
                  dto.type == "assistant",
                  let msg = dto.message,
                  let usage = msg.usage else { continue }

            let inTok = usage.input_tokens ?? 0
            let outTok = usage.output_tokens ?? 0
            let crTok = usage.cache_read_input_tokens ?? 0
            let cc1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
            let cc5m: Int64
            if let explicit5m = usage.cache_creation?.ephemeral_5m_input_tokens {
                cc5m = explicit5m
            } else {
                cc5m = max(0, (usage.cache_creation_input_tokens ?? 0) - cc1h)
            }
            let ccTotal = max(usage.cache_creation_input_tokens ?? 0, cc5m + cc1h)
            guard inTok > 0 || outTok > 0 || crTok > 0 || ccTotal > 0 else { continue }

            let msgId = msg.id ?? ""
            let reqId = dto.requestId ?? ""
            let tsStr = dto.timestamp ?? ""
            let ts = (!tsStr.isEmpty ? LocalDateFormatting.parseISO8601(tsStr) : nil) ?? mtime
            let (day, hour) = LocalDateFormatting.dayAndHour(from: ts)

            let resolvedSession = (dto.sessionId?.isEmpty == false) ? dto.sessionId! : fallbackSessionStem
            let resolvedProject = dto.cwd.flatMap(ProjectNormalizer.fromDirectoryPath) ?? folderProject

            let dedupeKey: String
            if !msgId.isEmpty || !reqId.isEmpty {
                dedupeKey = "cc:\(msgId):\(reqId)"
            } else {
                dedupeKey = "cc:\(resolvedSession):\(tsStr):\(inTok):\(outTok)"
            }

            let rawModel = msg.model ?? "claude-sonnet-4-5"
            let pricing = PricingCatalog.pricing(for: rawModel)
            let (cost, saved) = pricing.computeCost(
                input: inTok,
                output: outTok,
                cacheRead: crTok,
                cacheCreate: cc5m,
                cacheCreate1h: cc1h
            )

            records.append(UsageRecord(
                dedupeKey: dedupeKey,
                day: day,
                hour: hour,
                provider: ProviderKind.claude.rawValue,
                source: "claude-code",
                model: pricing.canonicalName,
                project: resolvedProject,
                sessionId: "cc:\(resolvedSession)",
                inputTokens: inTok,
                outputTokens: outTok,
                cacheReadTokens: crTok,
                cacheCreateTokens: ccTotal,
                costUSD: cost,
                cacheSavedUSD: saved,
                isEstimated: pricing.isEstimated
            ))
        }

        let newCursor = FileCursor(
            path: path,
            inode: inode,
            byteOffset: consumedOffset,
            lastStepIdx: -1,
            lastGenIdx: -1,
            mtimeNs: mtimeNs
        )
        return (records, newCursor)
    }
}

/// Incremental read-only parser for Antigravity `conversations/*.db`.
public enum AntigravityDBParser {
    public static func parseIncremental(
        dbURL: URL,
        sourceName: String,
        projectMap: [String: String],
        existingCursor: FileCursor?
    ) -> (records: [UsageRecord], cursor: FileCursor)? {
        let path = dbURL.path
        var dbSt = stat()
        guard stat(path, &dbSt) == 0 else { return nil }
        let inode = Int64(dbSt.st_ino)
        let dbMtimeNs = Int64(dbSt.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(dbSt.st_mtimespec.tv_nsec)
        var walSt = stat()
        let walMtimeNs: Int64 = (stat(path + "-wal", &walSt) == 0)
            ? (Int64(walSt.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(walSt.st_mtimespec.tv_nsec))
            : dbMtimeNs
        let mtimeNs = max(dbMtimeNs, walMtimeNs)
        let effectiveMtime = Date(timeIntervalSince1970: Double(mtimeNs) / 1_000_000_000.0)

        let lastStep = (existingCursor?.inode == inode) ? (existingCursor?.lastStepIdx ?? -1) : -1
        let lastGen = (existingCursor?.inode == inode) ? (existingCursor?.lastGenIdx ?? -1) : -1
        if let cur = existingCursor, cur.inode == inode, cur.mtimeNs == mtimeNs {
            return nil // Unchanged
        }

        let convId = dbURL.deletingPathExtension().lastPathComponent
        let project = projectMap[convId] ?? "general"
        var records: [UsageRecord] = []
        var maxFinalStep = lastStep
        var maxGenIdx = lastGen

        do {
            try SafeReadOnlySQLite.withConnection(to: path) { db in
                // 1. Read gen_metadata for accurate model slugs + responseId mapping
                var responseToSlug: [String: String] = [:]
                var enumToSlug: [UInt64: String] = [:]
                var genEntries: [(idx: Int64, decoded: AntigravityGenDecoded)] = []

                var stmt: OpaquePointer?
                let genSQL = "SELECT idx, data FROM gen_metadata WHERE idx > ? ORDER BY idx ASC"
                if sqlite3_prepare_v2(db, genSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                    sqlite3_bind_int64(s, 1, lastGen)
                    while sqlite3_step(s) == SQLITE_ROW {
                        let idx = sqlite3_column_int64(s, 0)
                        if idx > maxGenIdx { maxGenIdx = idx }
                        guard let ptr = sqlite3_column_blob(s, 1) else { continue }
                        let len = Int(sqlite3_column_bytes(s, 1))
                        guard len > 0 else { continue }
                        let blobData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr), count: len, deallocator: .none)
                        let decoded = AntigravityBlobDecoder.decodeGenMetadata(blobData)
                        if !decoded.modelSlug.isEmpty {
                            if decoded.modelEnum > 0 { enumToSlug[decoded.modelEnum] = decoded.modelSlug }
                            if let key = decoded.usage?.stableKey { responseToSlug[key] = decoded.modelSlug }
                        }
                        if decoded.usage != nil {
                            genEntries.append((idx, decoded))
                        }
                    }
                    sqlite3_finalize(s)
                }

                // 2. Read steps (new or unfinished status != 3) for accurate timestamps + usage
                var stepTimestamps: [Int: Date] = [:]
                var seenResponseKeys = Set<String>()
                let stepSQL = "SELECT idx, status, metadata FROM steps WHERE (idx > ? OR status != 3) AND metadata IS NOT NULL ORDER BY idx ASC"
                if sqlite3_prepare_v2(db, stepSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                    sqlite3_bind_int64(s, 1, lastStep)
                    while sqlite3_step(s) == SQLITE_ROW {
                        let idx = sqlite3_column_int64(s, 0)
                        let status = sqlite3_column_int(s, 1)
                        if status == 3 && idx > maxFinalStep { maxFinalStep = idx }
                        guard let ptr = sqlite3_column_blob(s, 2) else { continue }
                        let len = Int(sqlite3_column_bytes(s, 2))
                        guard len > 0 else { continue }

                        let blobData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr), count: len, deallocator: .none)
                        let decoded = AntigravityBlobDecoder.decodeStepMetadata(blobData)
                        if let ts = decoded.timestamp {
                            stepTimestamps[Int(idx)] = ts
                        }
                        guard let u = decoded.usage, u.hasTokens else { continue }

                        let stableKey = u.stableKey ?? "step:\(convId):\(idx)"
                        seenResponseKeys.insert(stableKey)
                        let mEnum = u.modelEnum > 0 ? u.modelEnum : decoded.modelEnum
                        let rawModel = responseToSlug[stableKey]
                            ?? enumToSlug[mEnum]
                            ?? PricingCatalog.modelSlug(forEnum: mEnum)
                        let pricing = PricingCatalog.pricing(for: rawModel)
                        let (cost, saved) = pricing.computeCost(
                            input: u.inputTokens,
                            output: u.outputTokens,
                            cacheRead: u.cacheReadTokens,
                            cacheCreate: u.cacheCreateTokens
                        )
                        let ts = decoded.timestamp ?? effectiveMtime
                        let (day, hour) = LocalDateFormatting.dayAndHour(from: ts)

                        records.append(UsageRecord(
                            dedupeKey: "agy:\(stableKey)",
                            day: day,
                            hour: hour,
                            provider: ProviderKind.antigravity.rawValue,
                            source: sourceName,
                            model: pricing.canonicalName,
                            project: project,
                            sessionId: "agy:\(convId)",
                            inputTokens: u.inputTokens,
                            outputTokens: u.outputTokens,
                            cacheReadTokens: u.cacheReadTokens,
                            cacheCreateTokens: u.cacheCreateTokens,
                            costUSD: cost,
                            cacheSavedUSD: saved,
                            isEstimated: pricing.isEstimated
                        ))
                    }
                    sqlite3_finalize(s)
                }

                // 3. Emit any gen_metadata usages not already captured from steps
                for (gIdx, g) in genEntries {
                    guard let u = g.usage, u.hasTokens else { continue }
                    let stableKey = u.stableKey ?? "gen:\(convId):\(gIdx)"
                    if seenResponseKeys.contains(stableKey) { continue }
                    let rawModel = !g.modelSlug.isEmpty
                        ? g.modelSlug
                        : (enumToSlug[u.modelEnum] ?? PricingCatalog.modelSlug(forEnum: u.modelEnum > 0 ? u.modelEnum : g.modelEnum))
                    let pricing = PricingCatalog.pricing(for: rawModel)
                    let (cost, saved) = pricing.computeCost(
                        input: u.inputTokens,
                        output: u.outputTokens,
                        cacheRead: u.cacheReadTokens,
                        cacheCreate: u.cacheCreateTokens
                    )
                    let ts = g.lastStepIndex.flatMap { stepTimestamps[$0] } ?? effectiveMtime
                    let (day, hour) = LocalDateFormatting.dayAndHour(from: ts)

                    records.append(UsageRecord(
                        dedupeKey: "agy:\(stableKey)",
                        day: day,
                        hour: hour,
                        provider: ProviderKind.antigravity.rawValue,
                        source: sourceName,
                        model: pricing.canonicalName,
                        project: project,
                        sessionId: "agy:\(convId)",
                        inputTokens: u.inputTokens,
                        outputTokens: u.outputTokens,
                        cacheReadTokens: u.cacheReadTokens,
                        cacheCreateTokens: u.cacheCreateTokens,
                        costUSD: cost,
                        cacheSavedUSD: saved,
                        isEstimated: pricing.isEstimated
                    ))
                }
            }
        } catch {
            return nil
        }

        let newCursor = FileCursor(
            path: path,
            inode: inode,
            byteOffset: 0,
            lastStepIdx: maxFinalStep,
            lastGenIdx: maxGenIdx,
            mtimeNs: mtimeNs
        )
        return (records, newCursor)
    }
}
