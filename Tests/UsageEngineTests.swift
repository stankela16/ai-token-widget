import XCTest
@testable import Milkit

final class UsageEngineTests: XCTestCase {

    func testPricingCatalogAndFallbackEstimation() {
        let opus = PricingCatalog.pricing(for: "claude-opus-5-5")
        XCTAssertFalse(opus.isEstimated)
        let (cost, saved) = opus.computeCost(input: 1_000_000, output: 100_000, cacheRead: 1_000_000, cacheCreate: 0)
        // 5.0 + 2.5 + 0.5 = 8.0 ; saved = 5.0 - 0.5 = 4.5
        XCTAssertEqual(cost, 8.0, accuracy: 0.001)
        XCTAssertEqual(saved, 4.5, accuracy: 0.001)

        let unknown = PricingCatalog.pricing(for: "brand-new-model-x9")
        XCTAssertTrue(unknown.isEstimated)
        let (uCost, _) = unknown.computeCost(input: 1_000_000, output: 0, cacheRead: 0, cacheCreate: 0)
        XCTAssertGreaterThan(uCost, 0)
    }

    func testRollupStoreMonotonicDeduplication() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("milkit-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try RollupStore(dbURL: tmp)
        let today = LocalDateFormatting.dayAndHour(from: Date())
        let cursor = FileCursor(path: "/tmp/a.jsonl", inode: 1, byteOffset: 100, lastStepIdx: -1, lastGenIdx: -1, mtimeNs: 1)

        // First streaming chunk: 100 output tokens
        let rec1 = UsageRecord(
            dedupeKey: "cc:msg1:req1",
            day: today.day,
            hour: today.hour,
            provider: "claude",
            source: "claude-code",
            model: "claude-opus-5-5",
            project: "milkit",
            sessionId: "s1",
            inputTokens: 1000,
            outputTokens: 100,
            cacheReadTokens: 5000,
            cacheCreateTokens: 0,
            costUSD: 0.01,
            cacheSavedUSD: 0.02,
            isEstimated: false
        )
        // Duplicate + expanded streaming chunk: 250 output tokens (delta should be +150, NOT +250!)
        let rec2 = UsageRecord(
            dedupeKey: "cc:msg1:req1",
            day: today.day,
            hour: today.hour,
            provider: "claude",
            source: "claude-code",
            model: "claude-opus-5-5",
            project: "milkit",
            sessionId: "s1",
            inputTokens: 1000,
            outputTokens: 250,
            cacheReadTokens: 5000,
            cacheCreateTokens: 0,
            costUSD: 0.025,
            cacheSavedUSD: 0.02,
            isEstimated: false
        )

        try store.saveBatch(records: [rec1, rec2], cursor: cursor)
        let snap = store.buildSnapshot(providerFilter: .all, rangeDays: 7, quotas: [], ingestion: .idle)
        XCTAssertEqual(snap.today.inputTokens, 1000)
        XCTAssertEqual(snap.today.outputTokens, 250)
        XCTAssertEqual(snap.today.cacheReadTokens, 5000)
        XCTAssertEqual(snap.today.costUSD, 0.025, accuracy: 0.0001)
    }

    func testQuotaItemAutoResetAndStaleLabel() {
        let expired = QuotaItem(
            id: "q1",
            label: "Claude 5h",
            sublabel: "Session",
            provider: .claude,
            usedFraction: 0.85,
            resetsAt: Date().addingTimeInterval(-300),
            fetchedAt: Date().addingTimeInterval(-7200),
            isAvailable: true
        )
        XCTAssertTrue(expired.isExpired)
        XCTAssertEqual(expired.effectiveUsedPercent, 0)
        XCTAssertNil(expired.staleLabel)

        let stale = QuotaItem(
            id: "q2",
            label: "AGY P4",
            sublabel: "Ultra",
            provider: .antigravity,
            usedFraction: 0.42,
            resetsAt: Date().addingTimeInterval(3600),
            fetchedAt: Date().addingTimeInterval(-5400),
            isAvailable: true
        )
        XCTAssertFalse(stale.isExpired)
        XCTAssertEqual(stale.effectiveUsedPercent, 42)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.staleLabel, "90m ago")
    }

    func testProjectNormalizerAndDirectoryPaths() {
        XCTAssertEqual(
            ProjectNormalizer.fromClaudeFolderName("-Users-alice-Developer-milkit"),
            "milkit"
        )
        XCTAssertEqual(
            ProjectNormalizer.fromClaudeFolderName("-Users-bob-workspace-nebula-api"),
            "nebula-api"
        )
        XCTAssertEqual(
            ProjectNormalizer.fromDirectoryPath("/Users/alice/src/swift-canvas"),
            "swift-canvas"
        )
    }

    func testClaudeJSONLSubagentAttributionAnd1hCachePricing() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("milkit-cc-test-\(UUID().uuidString)", isDirectory: true)
        let subagentDir = tmpRoot
            .appendingPathComponent("-Users-alice-Developer-nebula-api", isDirectory: true)
            .appendingPathComponent("parent-session-42", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let fileURL = subagentDir.appendingPathComponent("agent-a1.jsonl")
        let line = """
        {"type":"assistant","requestId":"req-1","sessionId":"parent-session-42","cwd":"/Users/alice/src/real-cwd-repo","timestamp":"2026-11-26T12:00:00Z","message":{"id":"msg-1","model":"claude-haiku-5-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":500000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":500000}}}}
        """ + "\n"
        try line.write(to: fileURL, atomically: true, encoding: .utf8)

        let parsed = ClaudeJSONLParser.parseIncremental(fileURL: fileURL, existingCursor: nil)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.records.count, 1)
        let rec = try XCTUnwrap(parsed?.records.first)
        XCTAssertEqual(rec.project, "real-cwd-repo")
        XCTAssertNotEqual(rec.project, "subagents")
        XCTAssertEqual(rec.sessionId, "cc:parent-session-42")
        XCTAssertFalse(rec.isEstimated)
        // claude-haiku-5-5: 1M in ($1.0) + 100k out ($0.5) + 500k 1h cache write (2.0x * $1.0 * 0.5 = $1.0) = $2.50
        XCTAssertEqual(rec.costUSD, 2.50, accuracy: 0.001)
    }

    func testPricingCatalogSuffixStrippingAndCodexModels() {
        XCTAssertEqual(PricingCatalog.normalizeModelName("model-high-20260901"), "model")
        XCTAssertEqual(PricingCatalog.normalizeModelName("gemini-2.5-pro-high-20260901"), "gemini-2.5-pro")
        let haiku5 = PricingCatalog.pricing(for: "claude-haiku-5-5-20260901")
        XCTAssertFalse(haiku5.isEstimated)
        XCTAssertEqual(haiku5.inputPerMillion, 1.0, accuracy: 0.001)

        let codex = PricingCatalog.pricing(for: "gpt-5.3-codex")
        XCTAssertFalse(codex.isEstimated)
        XCTAssertEqual(codex.inputPerMillion, 1.25, accuracy: 0.001)
        XCTAssertEqual(codex.outputPerMillion, 10.0, accuracy: 0.001)
    }

    func testDayBreakdownCountsDistinctSessions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("milkit-breakdown-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try RollupStore(dbURL: tmp)
        let today = LocalDateFormatting.dayAndHour(from: Date())
        let cursor = FileCursor(path: "/tmp/b.jsonl", inode: 2, byteOffset: 200, lastStepIdx: -1, lastGenIdx: -1, mtimeNs: 2)
        let r1 = UsageRecord(
            dedupeKey: "k1", day: today.day, hour: today.hour,
            provider: "claude", source: "claude-code", model: "claude-sonnet-4-5",
            project: "nebula-api", sessionId: "s1",
            inputTokens: 1000, outputTokens: 200, cacheReadTokens: 0, cacheCreateTokens: 0,
            costUSD: 0.10, cacheSavedUSD: 0, isEstimated: false
        )
        let r2 = UsageRecord(
            dedupeKey: "k2", day: today.day, hour: today.hour,
            provider: "claude", source: "claude-code", model: "claude-sonnet-4-5",
            project: "nebula-api", sessionId: "s2",
            inputTokens: 1000, outputTokens: 200, cacheReadTokens: 0, cacheCreateTokens: 0,
            costUSD: 0.15, cacheSavedUSD: 0, isEstimated: false
        )
        try store.saveBatch(records: [r1, r2], cursor: cursor)
        let snap = store.buildSnapshot(providerFilter: .all, rangeDays: 7, quotas: [], ingestion: .idle)
        let detail = store.dayBreakdown(for: snap.today, providerFilter: .all)
        XCTAssertEqual(detail.projects.first?.sessions, 2)
    }

    func testCodexJSONLParserExtractsProjectModelAndCachedTokens() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("milkit-codex-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("rollout-2026-11-26.jsonl")
        let content = """
        {"timestamp":"2026-11-26T14:00:00Z","type":"session_meta","payload":{"id":"codex-sess-1","cwd":"/Users/alice/Developer/milkit"}}
        {"timestamp":"2026-11-26T14:00:01Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
        {"timestamp":"2026-11-26T14:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":400000,"output_tokens":100000},"total_token_usage":{"total_tokens":1100000}}}}
        """ + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let parsed = CodexJSONLParser.parseIncremental(fileURL: fileURL, existingCursor: nil)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.records.count, 1)
        let rec = try XCTUnwrap(parsed?.records.first)
        XCTAssertEqual(rec.provider, ProviderKind.codex.rawValue)
        XCTAssertEqual(rec.project, "milkit")
        XCTAssertEqual(rec.model, "gpt-5.3-codex")
        XCTAssertEqual(rec.inputTokens, 600_000)
        XCTAssertEqual(rec.cacheReadTokens, 400_000)
        XCTAssertEqual(rec.outputTokens, 100_000)
        XCTAssertFalse(rec.isEstimated)
        // 0.6M * $1.25 ($0.75) + 0.4M * $0.125 ($0.05) + 0.1M * $10 ($1.00) = $1.80
        XCTAssertEqual(rec.costUSD, 1.80, accuracy: 0.001)
    }

    func testFastISO8601ParserMatchesFoundation() {
        let samples = [
            "2026-11-25T07:09:45.676Z",
            "2026-11-26T15:45:00Z",
            "2026-11-26T16:45:00+01:00"
        ]
        let ref = ISO8601DateFormatter()
        ref.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let refBasic = ISO8601DateFormatter()
        refBasic.formatOptions = [.withInternetDateTime]

        for s in samples {
            let parsed = LocalDateFormatting.parseISO8601(s)
            let expected = ref.date(from: s) ?? refBasic.date(from: s)
            XCTAssertNotNil(parsed)
            XCTAssertNotNil(expected)
            XCTAssertEqual(parsed!.timeIntervalSince1970, expected!.timeIntervalSince1970, accuracy: 0.002)
        }
    }

    func testCodexDuplicateTotalTokensWithNewTimestampIsDeduplicated() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("milkit-codex-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("rollout-2026-11-26.jsonl")
        let content = """
        {"timestamp":"2026-11-26T14:00:00Z","type":"session_meta","payload":{"id":"codex-sess-dup","cwd":"/Users/alice/Developer/milkit"}}
        {"timestamp":"2026-11-26T14:00:01Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
        {"timestamp":"2026-11-26T14:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":400000,"output_tokens":100000},"total_token_usage":{"total_tokens":1100000}}}}
        {"timestamp":"2026-11-26T14:00:09Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":400000,"output_tokens":100000},"total_token_usage":{"total_tokens":1100000}}}}
        """ + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let parsed = try XCTUnwrap(CodexJSONLParser.parseIncremental(fileURL: fileURL, existingCursor: nil))
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(parsed.records[0].dedupeKey, "codex:codex-sess-dup:total:1100000")
        XCTAssertEqual(parsed.records[1].dedupeKey, parsed.records[0].dedupeKey)

        let dbURL = tmpDir.appendingPathComponent("milkit-dedupe.sqlite")
        let store = try RollupStore(dbURL: dbURL)
        try store.saveBatch(records: parsed.records, cursor: parsed.cursor)
        let snap = store.buildSnapshot(providerFilter: .all, rangeDays: 30, quotas: [], ingestion: .idle)
        let proj = try XCTUnwrap(snap.projects.first(where: { $0.project == "milkit" }))
        XCTAssertEqual(proj.totalTokens, 1_100_000)
        XCTAssertEqual(proj.costUSD, 1.80, accuracy: 0.001)
    }

    func testMultiDaySessionCountsOncePerProject() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("milkit-multiday-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try RollupStore(dbURL: tmp)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let d1 = LocalDateFormatting.dayAndHour(from: yesterday)
        let d2 = LocalDateFormatting.dayAndHour(from: now)
        let cursor = FileCursor(path: "/tmp/multiday.jsonl", inode: 9, byteOffset: 300, lastStepIdx: -1, lastGenIdx: -1, mtimeNs: 9)

        let r1 = UsageRecord(
            dedupeKey: "md-1", day: d1.day, hour: d1.hour,
            provider: "claude", source: "claude-code", model: "claude-sonnet-4-5",
            project: "nebula-api", sessionId: "shared-session-1",
            inputTokens: 1000, outputTokens: 200, cacheReadTokens: 0, cacheCreateTokens: 0,
            costUSD: 0.10, cacheSavedUSD: 0, isEstimated: false
        )
        let r2 = UsageRecord(
            dedupeKey: "md-2", day: d2.day, hour: d2.hour,
            provider: "claude", source: "claude-code", model: "claude-sonnet-4-5",
            project: "nebula-api", sessionId: "shared-session-1",
            inputTokens: 1000, outputTokens: 200, cacheReadTokens: 0, cacheCreateTokens: 0,
            costUSD: 0.15, cacheSavedUSD: 0, isEstimated: false
        )
        try store.saveBatch(records: [r1, r2], cursor: cursor)
        let snap = store.buildSnapshot(providerFilter: .all, rangeDays: 7, quotas: [], ingestion: .idle)
        let proj = try XCTUnwrap(snap.projects.first(where: { $0.project == "nebula-api" }))
        XCTAssertEqual(proj.sessions, 1)
    }

    func testNumberFormattingRoundingAndClamping() {
        XCTAssertEqual(NumberFormatting.compactUSD(999.52), "$1.0K")
        XCTAssertEqual(NumberFormatting.compactUSD(999.4), "$999")
        XCTAssertEqual(NumberFormatting.compactUSD(-10), "$0.00")
        XCTAssertEqual(NumberFormatting.compactTokens(-42), "0")
        XCTAssertEqual(NumberFormatting.compactTokens(1_500_000), "1.5M")
    }
}
