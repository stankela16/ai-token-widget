import CoreServices
import Foundation
import os

/// Serialized background engine coordinating initial backfill, SQLite rollup queries,
/// and kernel `FSEvents` targeted single-file delta updates (`0.0%` idle CPU, `< 2 ms` live deltas).
public actor UsageEngine {
    private let logger = Logger(subsystem: "io.github.stankela16.milkit", category: "UsageEngine")
    private let home: URL
    private let store: RollupStore
    private var projectMap: [String: String] = [:]
    private var watcher: FSEventsWatcher?
    private var onSnapshot: (@Sendable (_ dashboard: UsageSnapshot, _ widget: UsageSnapshot) -> Void)?
    private var providerFilter: ProviderFilter = .all
    private var rangeDays: Int = 30
    private var lastStatus: IngestionStatus = .idle

    // Coalesced dirty paths from kernel FSEvents (eliminates storm scans)
    private var pendingPaths = Set<String>()
    private var pendingQuotaRefresh = false
    private var pendingProjectMapReload = false
    private var debounceTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0

    public init() throws {
        self.home = RealHomeResolver.homeDirectory
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Milkit", isDirectory: true)
            .appendingPathComponent("usage_rollup.sqlite")
        self.store = try RollupStore(dbURL: dbURL)
    }

    public func start(onSnapshot: @escaping @Sendable (_ dashboard: UsageSnapshot, _ widget: UsageSnapshot) -> Void) async {
        self.onSnapshot = onSnapshot

        // 1. Immediately emit cached snapshots (< 1 ms) so UI paints instantaneously on launch
        emitCurrentSnapshots()

        // 2. Run initial incremental scan (no-op < 10 ms if already indexed)
        await runFullIncrementalScan(fullProgressEmit: true)

        // 3. Start targeted kernel FSEvents watcher ONLY on token/quota paths
        startWatcher()
    }

    private func emitCurrentSnapshots() {
        let quotas = QuotaReader.readAll(home: home)
        let dash = store.buildSnapshot(
            providerFilter: providerFilter,
            rangeDays: rangeDays,
            quotas: quotas,
            ingestion: lastStatus
        )
        let widget: UsageSnapshot
        if providerFilter == .all && rangeDays == 30 {
            widget = dash
        } else {
            widget = store.buildSnapshot(
                providerFilter: .all,
                rangeDays: 30,
                quotas: quotas,
                ingestion: lastStatus
            )
        }
        onSnapshot?(dash, widget)
    }

    public func updateQuery(provider: ProviderFilter, rangeDays: Int) -> UsageSnapshot {
        self.providerFilter = provider
        self.rangeDays = rangeDays
        let quotas = QuotaReader.readAll(home: home)
        return store.buildSnapshot(
            providerFilter: providerFilter,
            rangeDays: rangeDays,
            quotas: quotas,
            ingestion: lastStatus
        )
    }

    public func dayBreakdown(for day: DayActivity) -> DayDetailBreakdown {
        store.dayBreakdown(for: day, providerFilter: providerFilter)
    }

    public func refreshNow() async {
        await runFullIncrementalScan(fullProgressEmit: false)
    }

    public func rebuildIndex() async {
        scanGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingPaths.removeAll()
        pendingQuotaRefresh = false
        pendingProjectMapReload = false
        do {
            try store.resetAll()
            await runFullIncrementalScan(fullProgressEmit: true)
        } catch {
            logger.error("Failed to reset rollup index: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Targeted FSEvents Watcher

    private func startWatcher() {
        let watchPaths = Self.discoverWatchPaths(home: home)
        guard !watchPaths.isEmpty else { return }

        watcher = FSEventsWatcher(paths: watchPaths, latency: 0.75) { [weak self] changedPaths in
            guard let self else { return }
            let relevant = changedPaths.filter { Self.isRelevantEventPath($0) }
            guard !relevant.isEmpty else { return }
            Task { await self.enqueueChangedPaths(relevant) }
        }
        watcher?.start()
    }

    private func enqueueChangedPaths(_ paths: [String]) {
        for raw in paths {
            if raw.hasSuffix(".claude.json") || raw.contains(".quota_cache_") {
                pendingQuotaRefresh = true
            } else if raw.hasSuffix("conversation_summaries.db") || raw.hasSuffix("conversation_summaries.db-wal") {
                pendingProjectMapReload = true
            } else if raw.hasSuffix(".jsonl") {
                pendingPaths.insert(raw)
            } else if raw.hasSuffix(".db-wal") {
                pendingPaths.insert(String(raw.dropLast(4))) // map .db-wal -> .db
            } else if raw.hasSuffix(".db") {
                pendingPaths.insert(raw)
            }
        }

        // Coalesce rapid streaming writes into a single < 2ms delta pass
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.processPendingDeltas()
        }
    }

    private func processPendingDeltas() async {
        let paths = pendingPaths
        let refreshQuotas = pendingQuotaRefresh
        let reloadMap = pendingProjectMapReload
        pendingPaths.removeAll()
        pendingQuotaRefresh = false
        pendingProjectMapReload = false

        guard !paths.isEmpty || refreshQuotas || reloadMap else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        if reloadMap || projectMap.isEmpty {
            projectMap = AntigravityProjectMapLoader.loadMap(home: home)
        }

        var anyChanged = false
        let claudeRoot = RealHomeResolver.claudeConfigDirectory.appendingPathComponent("projects").path
        let codexRoot = RealHomeResolver.codexHomeDirectory.appendingPathComponent("sessions").path

        for path in paths {
            autoreleasepool {
                let url = URL(fileURLWithPath: path)
                if path.hasSuffix(".jsonl") && path.hasPrefix(claudeRoot) {
                    let existing = store.cursor(for: path)
                    if let res = ClaudeJSONLParser.parseIncremental(fileURL: url, existingCursor: existing) {
                        do {
                            try store.saveBatch(records: res.records, cursor: res.cursor)
                            if !res.records.isEmpty { anyChanged = true }
                        } catch {
                            let fileName = url.lastPathComponent
                            logger.error("Failed saving Claude delta for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                } else if path.hasSuffix(".jsonl") && path.hasPrefix(codexRoot) {
                    let existing = store.cursor(for: path)
                    if let res = CodexJSONLParser.parseIncremental(fileURL: url, existingCursor: existing) {
                        do {
                            try store.saveBatch(records: res.records, cursor: res.cursor)
                            if !res.records.isEmpty { anyChanged = true }
                        } catch {
                            let fileName = url.lastPathComponent
                            logger.error("Failed saving Codex delta for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                } else if path.hasSuffix(".db") && path.contains("/conversations/") {
                    let source = Self.sourceName(forAntigravityPath: path)
                    let existing = store.cursor(for: path)
                    if let res = AntigravityDBParser.parseIncremental(
                        dbURL: url,
                        sourceName: source,
                        projectMap: projectMap,
                        existingCursor: existing
                    ) {
                        do {
                            try store.saveBatch(records: res.records, cursor: res.cursor)
                            if !res.records.isEmpty { anyChanged = true }
                        } catch {
                            let fileName = url.lastPathComponent
                            logger.error("Failed saving Antigravity delta for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }

        guard anyChanged || refreshQuotas else { return }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        lastStatus = IngestionStatus(
            isBackfilling: false,
            filesProcessed: lastStatus.filesTotal,
            filesTotal: lastStatus.filesTotal,
            claudeFileCount: lastStatus.claudeFileCount,
            codexFileCount: lastStatus.codexFileCount,
            agyDBCount: lastStatus.agyDBCount,
            lastDeltaMs: elapsedMs,
            lastUpdated: Date()
        )
        emitCurrentSnapshots()
    }

    // MARK: - Full Incremental Scan (Cold Start & Manual Refresh)

    private func runFullIncrementalScan(fullProgressEmit: Bool) async {
        scanGeneration &+= 1
        let myGeneration = scanGeneration
        let t0 = CFAbsoluteTimeGetCurrent()

        if projectMap.isEmpty || fullProgressEmit {
            projectMap = AntigravityProjectMapLoader.loadMap(home: home)
        }

        let (merged, claudeCount, codexCount, agyCount) = Self.discoverSourcesSorted(home: home)
        let totalCount = merged.count
        var processed = 0
        var anyChanged = false

        func emitIfNeeded(force: Bool = false) {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            lastStatus = IngestionStatus(
                isBackfilling: fullProgressEmit && processed < totalCount,
                filesProcessed: processed,
                filesTotal: totalCount,
                claudeFileCount: claudeCount,
                codexFileCount: codexCount,
                agyDBCount: agyCount,
                lastDeltaMs: force ? elapsedMs : lastStatus.lastDeltaMs,
                lastUpdated: Date()
            )
            guard force || (fullProgressEmit && (processed == 12 || processed % 60 == 0)) else { return }
            emitCurrentSnapshots()
        }

        for item in merged {
            guard myGeneration == scanGeneration else { return }
            autoreleasepool {
                switch item {
                case .claude(let url, _):
                    let existing = store.cursor(for: url.path)
                    if let result = ClaudeJSONLParser.parseIncremental(fileURL: url, existingCursor: existing) {
                        do {
                            try store.saveBatch(records: result.records, cursor: result.cursor)
                            if !result.records.isEmpty { anyChanged = true }
                        } catch {
                            logger.error("Failed saving Claude batch: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                case .codex(let url, _):
                    let existing = store.cursor(for: url.path)
                    if let result = CodexJSONLParser.parseIncremental(fileURL: url, existingCursor: existing) {
                        do {
                            try store.saveBatch(records: result.records, cursor: result.cursor)
                            if !result.records.isEmpty { anyChanged = true }
                        } catch {
                            logger.error("Failed saving Codex batch: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                case .agy(let url, let source, _):
                    let existing = store.cursor(for: url.path)
                    if let result = AntigravityDBParser.parseIncremental(
                        dbURL: url,
                        sourceName: source,
                        projectMap: projectMap,
                        existingCursor: existing
                    ) {
                        do {
                            try store.saveBatch(records: result.records, cursor: result.cursor)
                            if !result.records.isEmpty { anyChanged = true }
                        } catch {
                            logger.error("Failed saving Antigravity batch: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
            processed += 1
            emitIfNeeded()
            if processed % 20 == 0 {
                await Task.yield()
                guard myGeneration == scanGeneration else { return }
            }
        }

        guard myGeneration == scanGeneration else { return }
        _ = anyChanged
        emitIfNeeded(force: true)
    }

    // MARK: - Discovery Helpers (Nonisolated, Single C stat() Per File)

    private enum DiscoveredSource: Sendable {
        case claude(url: URL, mtimeSec: Int64)
        case codex(url: URL, mtimeSec: Int64)
        case agy(url: URL, source: String, mtimeSec: Int64)

        var mtimeSec: Int64 {
            switch self {
            case .claude(_, let t), .codex(_, let t), .agy(_, _, let t): t
            }
        }
    }

    private static nonisolated func discoverSourcesSorted(home: URL) -> ([DiscoveredSource], Int, Int, Int) {
        let fm = FileManager.default
        var items: [DiscoveredSource] = []
        var claudeCount = 0
        var codexCount = 0
        var agyCount = 0

        let claudeRoot = RealHomeResolver.claudeConfigDirectory.appendingPathComponent("projects")
        if let enumerator = fm.enumerator(
            at: claudeRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let obj = enumerator.nextObject() {
                if let url = obj as? URL, url.pathExtension == "jsonl" {
                    items.append(.claude(url: url, mtimeSec: fastMtimeSec(url.path)))
                    claudeCount += 1
                }
            }
        }

        let codexRoot = RealHomeResolver.codexHomeDirectory.appendingPathComponent("sessions")
        if let enumerator = fm.enumerator(
            at: codexRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let obj = enumerator.nextObject() {
                if let url = obj as? URL, url.pathExtension == "jsonl" {
                    items.append(.codex(url: url, mtimeSec: fastMtimeSec(url.path)))
                    codexCount += 1
                }
            }
        }

        let profilesRoot = home.appendingPathComponent("AntigravityProfiles")
        if let profiles = try? fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: nil) {
            for prof in profiles where prof.lastPathComponent.hasPrefix("Profile") {
                let pname = prof.lastPathComponent.lowercased()
                for sub in ["home/.gemini/antigravity", "home/.gemini/antigravity-ide", "home/.gemini/antigravity-cli"] {
                    let convDir = prof.appendingPathComponent(sub).appendingPathComponent("conversations")
                    if let dbs = try? fm.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) {
                        for db in dbs where db.pathExtension == "db" {
                            items.append(.agy(url: db, source: "agy-\(pname)", mtimeSec: fastMtimeSec(db.path)))
                            agyCount += 1
                        }
                    }
                }
            }
        }
        for sub in [".gemini/antigravity", ".gemini/antigravity-ide", ".gemini/antigravity-cli"] {
            let convDir = home.appendingPathComponent(sub).appendingPathComponent("conversations")
            if let dbs = try? fm.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) {
                for db in dbs where db.pathExtension == "db" {
                    items.append(.agy(url: db, source: "agy-default", mtimeSec: fastMtimeSec(db.path)))
                    agyCount += 1
                }
            }
        }

        // Schwartzian sort: zero syscalls inside comparator!
        items.sort { $0.mtimeSec > $1.mtimeSec }
        return (items, claudeCount, codexCount, agyCount)
    }

    private static nonisolated func discoverWatchPaths(home: URL) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []

        let claudeProj = RealHomeResolver.claudeConfigDirectory.appendingPathComponent("projects").path
        if fm.fileExists(atPath: claudeProj) { paths.append(claudeProj) }

        let claudeJson = home.appendingPathComponent(".claude.json").path
        if fm.fileExists(atPath: claudeJson) { paths.append(claudeJson) }

        let codexSessions = RealHomeResolver.codexHomeDirectory.appendingPathComponent("sessions").path
        if fm.fileExists(atPath: codexSessions) { paths.append(codexSessions) }

        let profilesRoot = home.appendingPathComponent("AntigravityProfiles")
        if let entries = try? fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix(".quota_cache_") && name.hasSuffix(".json") {
                    paths.append(entry.path)
                } else if name.hasPrefix("Profile") {
                    for sub in ["home/.gemini/antigravity", "home/.gemini/antigravity-ide", "home/.gemini/antigravity-cli"] {
                        let base = entry.appendingPathComponent(sub)
                        let convDir = base.appendingPathComponent("conversations").path
                        if fm.fileExists(atPath: convDir) { paths.append(convDir) }
                        let sumDB = base.appendingPathComponent("conversation_summaries.db").path
                        if fm.fileExists(atPath: sumDB) { paths.append(sumDB) }
                    }
                }
            }
        }
        for sub in [".gemini/antigravity", ".gemini/antigravity-ide", ".gemini/antigravity-cli"] {
            let base = home.appendingPathComponent(sub)
            let convDir = base.appendingPathComponent("conversations").path
            if fm.fileExists(atPath: convDir) { paths.append(convDir) }
            let sumDB = base.appendingPathComponent("conversation_summaries.db").path
            if fm.fileExists(atPath: sumDB) { paths.append(sumDB) }
            let sumWal = sumDB + "-wal"
            if fm.fileExists(atPath: sumWal) { paths.append(sumWal) }
        }
        return paths
    }

    private static nonisolated func isRelevantEventPath(_ path: String) -> Bool {
        if path.hasSuffix(".jsonl") {
            return path.contains("/projects/") || path.contains("/sessions/")
        }
        if path.hasSuffix(".db") || path.hasSuffix(".db-wal") {
            return path.contains("/conversations/") || path.contains("conversation_summaries.db")
        }
        if path.hasSuffix("/.claude.json") || path.contains(".quota_cache_") { return true }
        return false
    }

    private static nonisolated func sourceName(forAntigravityPath path: String) -> String {
        if let range = path.range(of: "/AntigravityProfiles/") {
            let after = path[range.upperBound...]
            if let slash = after.firstIndex(of: "/") {
                return "agy-\(after[..<slash].lowercased())"
            }
        }
        return "agy-default"
    }

    private static nonisolated func fastMtimeSec(_ path: String) -> Int64 {
        var st = stat()
        guard stat(path, &st) == 0 else { return 0 }
        return Int64(st.st_mtimespec.tv_sec)
    }
}

/// Thin Sendable wrapper around CoreServices FSEvents stream (kernel-level, 0.0% idle CPU).
private final class FSEventsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let callback: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.github.stankela16.milkit.fsevents", qos: .utility)

    init(paths: [String], latency: CFTimeInterval, callback: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.callback = callback
    }

    func start() {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes
        )
        let cb: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let changed = cfPaths as? [String], !changed.isEmpty else { return }
            watcher.callback(changed)
        }
        guard let ref = FSEventStreamCreate(
            nil,
            cb,
            &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        self.stream = ref
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
