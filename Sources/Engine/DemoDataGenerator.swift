import Foundation

/// Deterministic anonymized dataset for `--demo` CLI flag, Settings Demo Mode toggle,
/// screenshots, and Remotion/Hyperframe showcase videos (zero personal data).
public enum DemoDataGenerator {
    private static let demoProjects = [
        "nebula-api",
        "swift-canvas",
        "agent-evals",
        "coral-shader",
        "cli-router"
    ]

    public static func snapshot(providerFilter: ProviderFilter = .all, rangeDays: Int = 30) -> UsageSnapshot {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let start365 = cal.date(byAdding: .day, value: -364, to: todayStart) ?? todayStart
        var series: [DayActivity] = []
        series.reserveCapacity(365)

        // Deterministic pseudo-random wave concentrated in the most recent 14 weeks
        for offset in 0..<365 {
            guard let date = cal.date(byAdding: .day, value: offset, to: start365) else { continue }
            let dStr = fmt.string(from: date)
            let daysAgo = 364 - offset
            if daysAgo > 251 {
                series.append(.empty(day: dStr, date: date))
                continue
            }

            // Deterministic hash per day index
            let h = (offset * 1103515245 + 12345) & 0x7fffffff
            let weekday = (cal.component(.weekday, from: date) + 5) % 7 // 0=Mon..6=Sun

            // Guarantee an active 14-day streak ending today, with realistic dips on older weekends
            let active: Bool = if daysAgo < 14 {
                true
            } else if daysAgo < 70 {
                (weekday < 5) || (h % 3 == 0)
            } else {
                (h % 5 == 0)
            }

            guard active else {
                series.append(.empty(day: dStr, date: date))
                continue
            }

            let intensity = Double((h >> 8) % 100) / 100.0
            let recentBoost = daysAgo < 28 ? 1.45 : (daysAgo < 60 ? 1.05 : 0.72)
            let baseCost = (12.0 + intensity * 118.0) * recentBoost

            let claudePart = baseCost * 0.46
            let codexPart = baseCost * 0.28
            let agyPart = baseCost * 0.26

            let filteredCost: Double = switch providerFilter {
            case .all: baseCost
            case .claude: claudePart
            case .codex: codexPart
            case .antigravity: agyPart
            }

            let inTok = Int64(filteredCost * 110_000)
            let outTok = Int64(filteredCost * 14_000)
            let crTok = Int64(filteredCost * 1_650_000)
            let ccTok = Int64(filteredCost * 95_000)
            let saved = filteredCost * 3.85
            let sess = max(1, Int((filteredCost / 5.2).rounded()))
            let topProj = demoProjects[(h >> 4) % demoProjects.count]

            series.append(DayActivity(
                day: dStr,
                date: date,
                inputTokens: inTok,
                outputTokens: outTok,
                cacheReadTokens: crTok,
                cacheCreateTokens: ccTok,
                costUSD: filteredCost,
                cacheSavedUSD: saved,
                claudeCostUSD: providerFilter == .all || providerFilter == .claude ? claudePart : 0,
                codexCostUSD: providerFilter == .all || providerFilter == .codex ? codexPart : 0,
                agyCostUSD: providerFilter == .all || providerFilter == .antigravity ? agyPart : 0,
                sessions: sess,
                topProject: topProj,
                isEstimated: false
            ))
        }

        let rangeSlice = Array(series.suffix(max(1, min(365, rangeDays))))
        let totalRangeCost = rangeSlice.reduce(0.0) { $0 + $1.costUSD }
        let totalRangeTokens = rangeSlice.reduce(Int64(0)) { $0 + $1.totalTokens }
        let totalRangeSaved = rangeSlice.reduce(0.0) { $0 + $1.cacheSavedUSD }

        let weights: [(String, Double, Int)] = [
            ("nebula-api", 0.34, 42),
            ("swift-canvas", 0.26, 31),
            ("agent-evals", 0.19, 24),
            ("coral-shader", 0.13, 16),
            ("cli-router", 0.08, 11)
        ]
        let projects: [ProjectStat] = weights.map { name, w, s in
            let c = totalRangeCost * w
            return ProjectStat(
                project: name,
                totalTokens: Int64(Double(totalRangeTokens) * w),
                costUSD: c,
                cacheSavedUSD: totalRangeSaved * w,
                claudeCostUSD: providerFilter == .all || providerFilter == .claude ? c * 0.46 : 0,
                codexCostUSD: providerFilter == .all || providerFilter == .codex ? c * 0.28 : 0,
                agyCostUSD: providerFilter == .all || providerFilter == .antigravity ? c * 0.26 : 0,
                sessions: max(1, Int(Double(s) * Double(min(rangeDays, 30)) / 30.0))
            )
        }

        var models: [ModelStat] = []
        if providerFilter == .all || providerFilter == .claude {
            models.append(ModelStat(
                model: "claude-opus-4-6",
                provider: ProviderKind.claude.rawValue,
                inputTokens: Int64(Double(totalRangeTokens) * 0.03),
                outputTokens: Int64(Double(totalRangeTokens) * 0.004),
                cacheReadTokens: Int64(Double(totalRangeTokens) * 0.26),
                cacheCreateTokens: Int64(Double(totalRangeTokens) * 0.015),
                costUSD: totalRangeCost * 0.31,
                isEstimated: false
            ))
            models.append(ModelStat(
                model: "claude-sonnet-4-5",
                provider: ProviderKind.claude.rawValue,
                inputTokens: Int64(Double(totalRangeTokens) * 0.015),
                outputTokens: Int64(Double(totalRangeTokens) * 0.002),
                cacheReadTokens: Int64(Double(totalRangeTokens) * 0.12),
                cacheCreateTokens: Int64(Double(totalRangeTokens) * 0.008),
                costUSD: totalRangeCost * 0.15,
                isEstimated: false
            ))
        }
        if providerFilter == .all || providerFilter == .codex {
            models.append(ModelStat(
                model: "gpt-5.3-codex",
                provider: ProviderKind.codex.rawValue,
                inputTokens: Int64(Double(totalRangeTokens) * 0.025),
                outputTokens: Int64(Double(totalRangeTokens) * 0.005),
                cacheReadTokens: Int64(Double(totalRangeTokens) * 0.21),
                cacheCreateTokens: 0,
                costUSD: totalRangeCost * 0.28,
                isEstimated: false
            ))
        }
        if providerFilter == .all || providerFilter == .antigravity {
            models.append(ModelStat(
                model: "gemini-2.5-pro",
                provider: ProviderKind.antigravity.rawValue,
                inputTokens: Int64(Double(totalRangeTokens) * 0.02),
                outputTokens: Int64(Double(totalRangeTokens) * 0.004),
                cacheReadTokens: Int64(Double(totalRangeTokens) * 0.18),
                cacheCreateTokens: Int64(Double(totalRangeTokens) * 0.01),
                costUSD: totalRangeCost * 0.26,
                isEstimated: false
            ))
        }

        let now = Date()
        let quotas: [QuotaItem] = [
            QuotaItem(
                id: "demo-claude-5h",
                label: "Claude 5h",
                sublabel: "Session window",
                provider: .claude,
                usedFraction: 0.28,
                resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60),
                fetchedAt: now,
                isAvailable: true
            ),
            QuotaItem(
                id: "demo-codex-5h",
                label: "Codex 5h",
                sublabel: "Session window",
                provider: .codex,
                usedFraction: 0.16,
                resetsAt: now.addingTimeInterval(4 * 3600 + 10 * 60),
                fetchedAt: now,
                isAvailable: true
            ),
            QuotaItem(
                id: "demo-agy",
                label: "Antigravity",
                sublabel: "Pro · Gemini 84% 5h / 92% wk",
                provider: .antigravity,
                usedFraction: 0.16,
                resetsAt: now.addingTimeInterval(2 * 3600 + 45 * 60),
                fetchedAt: now,
                isAvailable: true
            )
        ]

        let todayActivity = series.last ?? .empty(day: fmt.string(from: todayStart), date: todayStart)
        return UsageSnapshot(
            generatedAt: now,
            dailySeries: series,
            today: todayActivity,
            currentStreakDays: 14,
            longestStreakDays: 28,
            projects: projects,
            models: models,
            quotas: quotas,
            ingestion: IngestionStatus(
                isBackfilling: false,
                filesProcessed: 128,
                filesTotal: 128,
                claudeFileCount: 64,
                codexFileCount: 32,
                agyDBCount: 32,
                lastDeltaMs: 1.2,
                lastUpdated: now
            )
        )
    }

    public static func dayBreakdown(for day: DayActivity) -> DayDetailBreakdown {
        let projects: [ProjectStat] = [
            ProjectStat(
                project: day.topProject.isEmpty ? "nebula-api" : day.topProject,
                totalTokens: Int64(Double(day.totalTokens) * 0.58),
                costUSD: day.costUSD * 0.58,
                cacheSavedUSD: day.cacheSavedUSD * 0.58,
                claudeCostUSD: day.claudeCostUSD * 0.58,
                codexCostUSD: day.codexCostUSD * 0.58,
                agyCostUSD: day.agyCostUSD * 0.58,
                sessions: max(1, day.sessions / 2)
            ),
            ProjectStat(
                project: "swift-canvas",
                totalTokens: Int64(Double(day.totalTokens) * 0.42),
                costUSD: day.costUSD * 0.42,
                cacheSavedUSD: day.cacheSavedUSD * 0.42,
                claudeCostUSD: day.claudeCostUSD * 0.42,
                codexCostUSD: day.codexCostUSD * 0.42,
                agyCostUSD: day.agyCostUSD * 0.42,
                sessions: max(1, day.sessions - max(1, day.sessions / 2))
            )
        ]
        let models: [ModelStat] = [
            ModelStat(
                model: "claude-opus-4-6",
                provider: ProviderKind.claude.rawValue,
                inputTokens: day.inputTokens / 2,
                outputTokens: day.outputTokens / 2,
                cacheReadTokens: day.cacheReadTokens / 2,
                cacheCreateTokens: day.cacheCreateTokens / 2,
                costUSD: day.costUSD * 0.46,
                isEstimated: false
            ),
            ModelStat(
                model: "gpt-5.3-codex",
                provider: ProviderKind.codex.rawValue,
                inputTokens: day.inputTokens / 3,
                outputTokens: day.outputTokens / 3,
                cacheReadTokens: day.cacheReadTokens / 3,
                cacheCreateTokens: 0,
                costUSD: day.costUSD * 0.28,
                isEstimated: false
            ),
            ModelStat(
                model: "gemini-2.5-pro",
                provider: ProviderKind.antigravity.rawValue,
                inputTokens: day.inputTokens / 6,
                outputTokens: day.outputTokens / 6,
                cacheReadTokens: day.cacheReadTokens / 6,
                cacheCreateTokens: day.cacheCreateTokens / 2,
                costUSD: day.costUSD * 0.26,
                isEstimated: false
            )
        ]
        return DayDetailBreakdown(day: day, projects: projects, models: models)
    }
}
