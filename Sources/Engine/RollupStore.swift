import Foundation
import SQLite3

public struct FileCursor: Sendable {
    public let path: String
    public var inode: Int64
    public var byteOffset: Int64
    public var lastStepIdx: Int64
    public var lastGenIdx: Int64
    public var mtimeNs: Int64
}

public struct UsageRecord: Sendable {
    public let dedupeKey: String
    public let day: String // YYYY-MM-DD (local)
    public let hour: Int
    public let provider: String
    public let source: String
    public let model: String
    public let project: String
    public let sessionId: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreateTokens: Int64
    public let costUSD: Double
    public let cacheSavedUSD: Double
    public let isEstimated: Bool
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local incremental SQLite rollup store (`usage_rollup.sqlite`).
/// All operations run serialized inside `UsageEngine` actor.
public final class RollupStore: @unchecked Sendable {
    private var db: OpaquePointer?
    public let dbURL: URL

    public init(dbURL: URL) throws {
        self.dbURL = dbURL
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try openAndMigrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func openAndMigrate() throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            dbURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "RollupStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "Failed to open rollup SQLite"])
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 3000)

        let ddl = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;

        CREATE TABLE IF NOT EXISTS file_cursors (
            path TEXT PRIMARY KEY,
            inode INTEGER NOT NULL DEFAULT 0,
            byte_offset INTEGER NOT NULL DEFAULT 0,
            last_step_idx INTEGER NOT NULL DEFAULT -1,
            last_gen_idx INTEGER NOT NULL DEFAULT -1,
            mtime_ns INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS dedupe_state (
            dedupe_key TEXT PRIMARY KEY,
            input_tok INTEGER NOT NULL DEFAULT 0,
            output_tok INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            cache_create INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            cache_saved REAL NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS hourly_cube (
            day TEXT NOT NULL,
            hour INTEGER NOT NULL,
            provider TEXT NOT NULL,
            source TEXT NOT NULL,
            model TEXT NOT NULL,
            project TEXT NOT NULL,
            input_tok INTEGER NOT NULL DEFAULT 0,
            output_tok INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            cache_create INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            cache_saved REAL NOT NULL DEFAULT 0,
            is_estimated INTEGER NOT NULL DEFAULT 0,
            turns INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, hour, provider, source, model, project)
        );
        CREATE INDEX IF NOT EXISTS idx_cube_day ON hourly_cube(day);
        CREATE INDEX IF NOT EXISTS idx_cube_provider_day ON hourly_cube(provider, day);

        CREATE TABLE IF NOT EXISTS day_sessions (
            day TEXT NOT NULL,
            session_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            project TEXT NOT NULL,
            PRIMARY KEY (day, session_id)
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_day ON day_sessions(day);
        """
        try exec(ddl)
    }

    public func resetAll() throws {
        try exec("""
        BEGIN IMMEDIATE;
        DELETE FROM file_cursors;
        DELETE FROM dedupe_state;
        DELETE FROM hourly_cube;
        DELETE FROM day_sessions;
        COMMIT;
        """)
    }

    public func cursor(for path: String) -> FileCursor? {
        guard let db else { return nil }
        let sql = "SELECT inode, byte_offset, last_step_idx, last_gen_idx, mtime_ns FROM file_cursors WHERE path = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return FileCursor(
            path: path,
            inode: sqlite3_column_int64(stmt, 0),
            byteOffset: sqlite3_column_int64(stmt, 1),
            lastStepIdx: sqlite3_column_int64(stmt, 2),
            lastGenIdx: sqlite3_column_int64(stmt, 3),
            mtimeNs: sqlite3_column_int64(stmt, 4)
        )
    }

    public func saveBatch(records: [UsageRecord], cursor: FileCursor) throws {
        guard let db else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            let selectDedupeSQL = "SELECT input_tok, output_tok, cache_read, cache_create, cost_usd, cache_saved FROM dedupe_state WHERE dedupe_key = ?"
            let upsertDedupeSQL = """
            INSERT INTO dedupe_state(dedupe_key, input_tok, output_tok, cache_read, cache_create, cost_usd, cache_saved)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dedupe_key) DO UPDATE SET
                input_tok = excluded.input_tok,
                output_tok = excluded.output_tok,
                cache_read = excluded.cache_read,
                cache_create = excluded.cache_create,
                cost_usd = excluded.cost_usd,
                cache_saved = excluded.cache_saved
            """
            let upsertCubeSQL = """
            INSERT INTO hourly_cube(day, hour, provider, source, model, project, input_tok, output_tok, cache_read, cache_create, cost_usd, cache_saved, is_estimated, turns)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, hour, provider, source, model, project) DO UPDATE SET
                input_tok = input_tok + excluded.input_tok,
                output_tok = output_tok + excluded.output_tok,
                cache_read = cache_read + excluded.cache_read,
                cache_create = cache_create + excluded.cache_create,
                cost_usd = cost_usd + excluded.cost_usd,
                cache_saved = cache_saved + excluded.cache_saved,
                is_estimated = MAX(is_estimated, excluded.is_estimated),
                turns = turns + excluded.turns
            """
            let upsertSessionSQL = "INSERT OR IGNORE INTO day_sessions(day, session_id, provider, project) VALUES(?, ?, ?, ?)"
            let upsertCursorSQL = """
            INSERT INTO file_cursors(path, inode, byte_offset, last_step_idx, last_gen_idx, mtime_ns)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                inode = excluded.inode,
                byte_offset = excluded.byte_offset,
                last_step_idx = excluded.last_step_idx,
                last_gen_idx = excluded.last_gen_idx,
                mtime_ns = excluded.mtime_ns
            """

            var selStmt: OpaquePointer?
            var dedStmt: OpaquePointer?
            var cubeStmt: OpaquePointer?
            var sesStmt: OpaquePointer?
            var curStmt: OpaquePointer?
            defer {
                sqlite3_finalize(selStmt)
                sqlite3_finalize(dedStmt)
                sqlite3_finalize(cubeStmt)
                sqlite3_finalize(sesStmt)
                sqlite3_finalize(curStmt)
            }

            func prepare(_ sql: String, into out: inout OpaquePointer?) throws {
                let rc = sqlite3_prepare_v2(db, sql, -1, &out, nil)
                guard rc == SQLITE_OK else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    throw NSError(domain: "RollupStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(msg)"])
                }
            }
            func stepDone(_ stmt: OpaquePointer?, label: String) throws {
                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    throw NSError(domain: "RollupStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "\(label) failed: \(msg)"])
                }
            }

            try prepare(selectDedupeSQL, into: &selStmt)
            try prepare(upsertDedupeSQL, into: &dedStmt)
            try prepare(upsertCubeSQL, into: &cubeStmt)
            try prepare(upsertSessionSQL, into: &sesStmt)
            try prepare(upsertCursorSQL, into: &curStmt)

            for r in records {
                // 1. Lookup existing dedupe state
                var oldIn: Int64 = 0, oldOut: Int64 = 0, oldCR: Int64 = 0, oldCC: Int64 = 0
                var oldCost = 0.0, oldSaved = 0.0
                var existed = false

                sqlite3_reset(selStmt)
                sqlite3_bind_text(selStmt, 1, r.dedupeKey, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                if sqlite3_step(selStmt) == SQLITE_ROW {
                    existed = true
                    oldIn = sqlite3_column_int64(selStmt, 0)
                    oldOut = sqlite3_column_int64(selStmt, 1)
                    oldCR = sqlite3_column_int64(selStmt, 2)
                    oldCC = sqlite3_column_int64(selStmt, 3)
                    oldCost = sqlite3_column_double(selStmt, 4)
                    oldSaved = sqlite3_column_double(selStmt, 5)
                }

                // 2. Mathematically exact monotonic delta: max(old, new) - old
                let newIn = max(oldIn, r.inputTokens)
                let newOut = max(oldOut, r.outputTokens)
                let newCR = max(oldCR, r.cacheReadTokens)
                let newCC = max(oldCC, r.cacheCreateTokens)
                let newCost = max(oldCost, r.costUSD)
                let newSaved = max(oldSaved, r.cacheSavedUSD)

                let dIn = newIn - oldIn
                let dOut = newOut - oldOut
                let dCR = newCR - oldCR
                let dCC = newCC - oldCC
                let dCost = newCost - oldCost
                let dSaved = newSaved - oldSaved
                let dTurns: Int64 = existed ? 0 : 1

                if !existed || dIn > 0 || dOut > 0 || dCR > 0 || dCC > 0 || dCost > 1e-9 {
                    sqlite3_reset(dedStmt)
                    sqlite3_bind_text(dedStmt, 1, r.dedupeKey, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_int64(dedStmt, 2, newIn)
                    sqlite3_bind_int64(dedStmt, 3, newOut)
                    sqlite3_bind_int64(dedStmt, 4, newCR)
                    sqlite3_bind_int64(dedStmt, 5, newCC)
                    sqlite3_bind_double(dedStmt, 6, newCost)
                    sqlite3_bind_double(dedStmt, 7, newSaved)
                    try stepDone(dedStmt, label: "upsert dedupe")

                    sqlite3_reset(cubeStmt)
                    sqlite3_bind_text(cubeStmt, 1, r.day, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_int(cubeStmt, 2, Int32(r.hour))
                    sqlite3_bind_text(cubeStmt, 3, r.provider, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(cubeStmt, 4, r.source, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(cubeStmt, 5, r.model, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(cubeStmt, 6, r.project, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_int64(cubeStmt, 7, dIn)
                    sqlite3_bind_int64(cubeStmt, 8, dOut)
                    sqlite3_bind_int64(cubeStmt, 9, dCR)
                    sqlite3_bind_int64(cubeStmt, 10, dCC)
                    sqlite3_bind_double(cubeStmt, 11, dCost)
                    sqlite3_bind_double(cubeStmt, 12, dSaved)
                    sqlite3_bind_int(cubeStmt, 13, r.isEstimated ? 1 : 0)
                    sqlite3_bind_int64(cubeStmt, 14, dTurns)
                    try stepDone(cubeStmt, label: "upsert cube")
                }

                if !r.sessionId.isEmpty {
                    sqlite3_reset(sesStmt)
                    sqlite3_bind_text(sesStmt, 1, r.day, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(sesStmt, 2, r.sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(sesStmt, 3, r.provider, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(sesStmt, 4, r.project, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    try stepDone(sesStmt, label: "upsert session")
                }
            }

            sqlite3_reset(curStmt)
            sqlite3_bind_text(curStmt, 1, cursor.path, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(curStmt, 2, cursor.inode)
            sqlite3_bind_int64(curStmt, 3, cursor.byteOffset)
            sqlite3_bind_int64(curStmt, 4, cursor.lastStepIdx)
            sqlite3_bind_int64(curStmt, 5, cursor.lastGenIdx)
            sqlite3_bind_int64(curStmt, 6, cursor.mtimeNs)
            try stepDone(curStmt, label: "upsert cursor")

            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func buildSnapshot(
        providerFilter: ProviderFilter = .all,
        rangeDays: Int = 365,
        quotas: [QuotaItem],
        ingestion: IngestionStatus
    ) -> UsageSnapshot {
        guard let db else { return .empty }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        // Always build full 365-day daily series for heatmap + streaks
        let start365 = cal.date(byAdding: .day, value: -364, to: todayStart) ?? todayStart
        let start365Str = fmt.string(from: start365)
        let rangeStart = cal.date(byAdding: .day, value: -(max(1, rangeDays) - 1), to: todayStart) ?? todayStart
        let rangeStartStr = fmt.string(from: rangeStart)
        let todayStr = fmt.string(from: todayStart)

        let provClause = providerFilter.providerRawValue.map { " AND provider = '\($0)'" } ?? ""

        // 1. Session counts per day
        var sessionsByDay: [String: Int] = [:]
        var stmt: OpaquePointer?
        let sesSQL = "SELECT day, COUNT(*) FROM day_sessions WHERE day >= ?\(provClause) GROUP BY day"
        if sqlite3_prepare_v2(db, sesSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, start365Str, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                if let cDay = sqlite3_column_text(s, 0) {
                    sessionsByDay[String(cString: cDay)] = Int(sqlite3_column_int(s, 1))
                }
            }
            sqlite3_finalize(s)
        }

        // 2. Top project per day
        var topProjectByDay: [String: (project: String, cost: Double)] = [:]
        let topProjSQL = "SELECT day, project, SUM(cost_usd) as c FROM hourly_cube WHERE day >= ?\(provClause) GROUP BY day, project"
        if sqlite3_prepare_v2(db, topProjSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, start365Str, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                guard let cDay = sqlite3_column_text(s, 0), let cProj = sqlite3_column_text(s, 1) else { continue }
                let d = String(cString: cDay)
                let p = String(cString: cProj)
                let cost = sqlite3_column_double(s, 2)
                if let cur = topProjectByDay[d] {
                    if cost > cur.cost { topProjectByDay[d] = (p, cost) }
                } else {
                    topProjectByDay[d] = (p, cost)
                }
            }
            sqlite3_finalize(s)
        }

        // 3. Daily totals for last 365 days
        struct DayAgg {
            var inTok: Int64 = 0, outTok: Int64 = 0, crTok: Int64 = 0, ccTok: Int64 = 0
            var cost = 0.0, saved = 0.0, claudeCost = 0.0, codexCost = 0.0, agyCost = 0.0
            var est = false
        }
        var dayMap: [String: DayAgg] = [:]
        let dailySQL = """
        SELECT day,
               SUM(input_tok), SUM(output_tok), SUM(cache_read), SUM(cache_create),
               SUM(cost_usd), SUM(cache_saved),
               SUM(CASE WHEN provider='claude' THEN cost_usd ELSE 0 END),
               SUM(CASE WHEN provider='codex' THEN cost_usd ELSE 0 END),
               SUM(CASE WHEN provider='antigravity' THEN cost_usd ELSE 0 END),
               MAX(is_estimated)
        FROM hourly_cube
        WHERE day >= ?\(provClause)
        GROUP BY day
        """
        if sqlite3_prepare_v2(db, dailySQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, start365Str, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                guard let cDay = sqlite3_column_text(s, 0) else { continue }
                let d = String(cString: cDay)
                dayMap[d] = DayAgg(
                    inTok: sqlite3_column_int64(s, 1),
                    outTok: sqlite3_column_int64(s, 2),
                    crTok: sqlite3_column_int64(s, 3),
                    ccTok: sqlite3_column_int64(s, 4),
                    cost: sqlite3_column_double(s, 5),
                    saved: sqlite3_column_double(s, 6),
                    claudeCost: sqlite3_column_double(s, 7),
                    codexCost: sqlite3_column_double(s, 8),
                    agyCost: sqlite3_column_double(s, 9),
                    est: sqlite3_column_int(s, 10) != 0
                )
            }
            sqlite3_finalize(s)
        }

        var series: [DayActivity] = []
        series.reserveCapacity(365)
        for offset in 0..<365 {
            guard let date = cal.date(byAdding: .day, value: offset, to: start365) else { continue }
            let dStr = fmt.string(from: date)
            if let agg = dayMap[dStr] {
                series.append(DayActivity(
                    day: dStr,
                    date: date,
                    inputTokens: agg.inTok,
                    outputTokens: agg.outTok,
                    cacheReadTokens: agg.crTok,
                    cacheCreateTokens: agg.ccTok,
                    costUSD: agg.cost,
                    cacheSavedUSD: agg.saved,
                    claudeCostUSD: agg.claudeCost,
                    codexCostUSD: agg.codexCost,
                    agyCostUSD: agg.agyCost,
                    sessions: max(sessionsByDay[dStr] ?? 0, agg.cost > 0 ? 1 : 0),
                    topProject: topProjectByDay[dStr]?.project ?? "general",
                    isEstimated: agg.est
                ))
            } else {
                series.append(.empty(day: dStr, date: date))
            }
        }

        // Compute current & longest streaks (consecutive active days ending today or yesterday)
        var longest = 0, run = 0
        for item in series {
            if item.costUSD > 0.0001 || item.totalTokens > 0 {
                run += 1
                if run > longest { longest = run }
            } else {
                run = 0
            }
        }
        var current = 0
        var idx = series.count - 1
        // Allow today to still be 0 if user hasn't run a prompt yet this morning
        if idx >= 0 && series[idx].costUSD <= 0.0001 && series[idx].totalTokens == 0 {
            idx -= 1
        }
        while idx >= 0 && (series[idx].costUSD > 0.0001 || series[idx].totalTokens > 0) {
            current += 1
            idx -= 1
        }

        // 4. Projects breakdown within rangeDays
        var projSessions: [String: Int] = [:]
        let psSQL = "SELECT project, COUNT(DISTINCT session_id) FROM day_sessions WHERE day >= ?\(provClause) GROUP BY project"
        if sqlite3_prepare_v2(db, psSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, rangeStartStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                if let cp = sqlite3_column_text(s, 0) {
                    projSessions[String(cString: cp)] = Int(sqlite3_column_int(s, 1))
                }
            }
            sqlite3_finalize(s)
        }

        var projects: [ProjectStat] = []
        let projSQL = """
        SELECT project,
               SUM(input_tok + output_tok + cache_read + cache_create),
               SUM(cost_usd), SUM(cache_saved),
               SUM(CASE WHEN provider='claude' THEN cost_usd ELSE 0 END),
               SUM(CASE WHEN provider='codex' THEN cost_usd ELSE 0 END),
               SUM(CASE WHEN provider='antigravity' THEN cost_usd ELSE 0 END)
        FROM hourly_cube
        WHERE day >= ?\(provClause)
        GROUP BY project
        ORDER BY SUM(cost_usd) DESC
        LIMIT 40
        """
        if sqlite3_prepare_v2(db, projSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, rangeStartStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                guard let cp = sqlite3_column_text(s, 0) else { continue }
                let name = String(cString: cp)
                projects.append(ProjectStat(
                    project: name,
                    totalTokens: sqlite3_column_int64(s, 1),
                    costUSD: sqlite3_column_double(s, 2),
                    cacheSavedUSD: sqlite3_column_double(s, 3),
                    claudeCostUSD: sqlite3_column_double(s, 4),
                    codexCostUSD: sqlite3_column_double(s, 5),
                    agyCostUSD: sqlite3_column_double(s, 6),
                    sessions: max(1, projSessions[name] ?? 0)
                ))
            }
            sqlite3_finalize(s)
        }

        // 5. Models breakdown within rangeDays
        var models: [ModelStat] = []
        let modelSQL = """
        SELECT model, provider,
               SUM(input_tok), SUM(output_tok), SUM(cache_read), SUM(cache_create),
               SUM(cost_usd), MAX(is_estimated)
        FROM hourly_cube
        WHERE day >= ?\(provClause)
        GROUP BY model, provider
        ORDER BY SUM(cost_usd) DESC
        LIMIT 40
        """
        if sqlite3_prepare_v2(db, modelSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, rangeStartStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                guard let cm = sqlite3_column_text(s, 0), let cp = sqlite3_column_text(s, 1) else { continue }
                models.append(ModelStat(
                    model: String(cString: cm),
                    provider: String(cString: cp),
                    inputTokens: sqlite3_column_int64(s, 2),
                    outputTokens: sqlite3_column_int64(s, 3),
                    cacheReadTokens: sqlite3_column_int64(s, 4),
                    cacheCreateTokens: sqlite3_column_int64(s, 5),
                    costUSD: sqlite3_column_double(s, 6),
                    isEstimated: sqlite3_column_int(s, 7) != 0
                ))
            }
            sqlite3_finalize(s)
        }

        let todayActivity = series.last(where: { $0.day == todayStr }) ?? .empty(day: todayStr, date: todayStart)
        return UsageSnapshot(
            generatedAt: Date(),
            dailySeries: series,
            today: todayActivity,
            currentStreakDays: current,
            longestStreakDays: longest,
            projects: projects,
            models: models,
            quotas: quotas,
            ingestion: ingestion
        )
    }

    public func dayBreakdown(for day: DayActivity, providerFilter: ProviderFilter = .all) -> DayDetailBreakdown {
        guard let db else { return DayDetailBreakdown(day: day, projects: [], models: []) }
        let provClause = providerFilter.providerRawValue.map { " AND provider = '\($0)'" } ?? ""

        var projSessions: [String: Int] = [:]
        var stmt: OpaquePointer?
        let psSQL = "SELECT project, COUNT(DISTINCT session_id) FROM day_sessions WHERE day = ?\(provClause) GROUP BY project"
        if sqlite3_prepare_v2(db, psSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, day.day, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                if let cp = sqlite3_column_text(s, 0) {
                    projSessions[String(cString: cp)] = Int(sqlite3_column_int(s, 1))
                }
            }
            sqlite3_finalize(s)
        }

        var projects: [ProjectStat] = []
        let pSQL = """
        SELECT project,
               SUM(input_tok + output_tok + cache_read + cache_create),
               SUM(cost_usd), SUM(cache_saved),
               SUM(CASE WHEN provider='claude' THEN cost_usd ELSE 0 END),
               SUM(CASE WHEN provider='codex' THEN cost_usd ELSE 0 END),
               SUM(CASE WHEN provider='antigravity' THEN cost_usd ELSE 0 END)
        FROM hourly_cube
        WHERE day = ?\(provClause)
        GROUP BY project
        ORDER BY SUM(cost_usd) DESC
        """
        if sqlite3_prepare_v2(db, pSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, day.day, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                guard let cp = sqlite3_column_text(s, 0) else { continue }
                let projName = String(cString: cp)
                projects.append(ProjectStat(
                    project: projName,
                    totalTokens: sqlite3_column_int64(s, 1),
                    costUSD: sqlite3_column_double(s, 2),
                    cacheSavedUSD: sqlite3_column_double(s, 3),
                    claudeCostUSD: sqlite3_column_double(s, 4),
                    codexCostUSD: sqlite3_column_double(s, 5),
                    agyCostUSD: sqlite3_column_double(s, 6),
                    sessions: max(1, projSessions[projName] ?? 1)
                ))
            }
            sqlite3_finalize(s)
        }

        var models: [ModelStat] = []
        let mSQL = """
        SELECT model, provider,
               SUM(input_tok), SUM(output_tok), SUM(cache_read), SUM(cache_create),
               SUM(cost_usd), MAX(is_estimated)
        FROM hourly_cube
        WHERE day = ?\(provClause)
        GROUP BY model, provider
        ORDER BY SUM(cost_usd) DESC
        """
        if sqlite3_prepare_v2(db, mSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            sqlite3_bind_text(s, 1, day.day, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            while sqlite3_step(s) == SQLITE_ROW {
                guard let cm = sqlite3_column_text(s, 0), let cp = sqlite3_column_text(s, 1) else { continue }
                models.append(ModelStat(
                    model: String(cString: cm),
                    provider: String(cString: cp),
                    inputTokens: sqlite3_column_int64(s, 2),
                    outputTokens: sqlite3_column_int64(s, 3),
                    cacheReadTokens: sqlite3_column_int64(s, 4),
                    cacheCreateTokens: sqlite3_column_int64(s, 5),
                    costUSD: sqlite3_column_double(s, 6),
                    isEstimated: sqlite3_column_int(s, 7) != 0
                ))
            }
            sqlite3_finalize(s)
        }

        return DayDetailBreakdown(day: day, projects: projects, models: models)
    }

    private func exec(_ sql: String) throws {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw NSError(domain: "RollupStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
