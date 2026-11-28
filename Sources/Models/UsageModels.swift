import Foundation

public enum ProviderKind: String, Sendable, CaseIterable, Identifiable, Codable {
    case claude = "claude"
    case codex = "codex"
    case antigravity = "antigravity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .antigravity: "Antigravity"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }
}

public enum ProviderFilter: String, Sendable, CaseIterable, Identifiable {
    case all = "All"
    case claude = "Claude"
    case codex = "Codex"
    case antigravity = "Antigravity"

    public var id: String { rawValue }

    public var providerRawValue: String? {
        switch self {
        case .all: nil
        case .claude: ProviderKind.claude.rawValue
        case .codex: ProviderKind.codex.rawValue
        case .antigravity: ProviderKind.antigravity.rawValue
        }
    }

    public func matches(_ provider: String) -> Bool {
        guard let raw = providerRawValue else { return true }
        return provider == raw
    }
}

public enum HeatmapMetric: String, Sendable, CaseIterable, Identifiable, Codable {
    case usd = "USD"
    case tokens = "Tokens"
    case sessions = "Sessions"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .usd: "dollarsign.circle"
        case .tokens: "cpu"
        case .sessions: "bolt.horizontal.circle"
        }
    }
}

public enum TimeRangeFilter: String, Sendable, CaseIterable, Identifiable {
    case days7 = "7D"
    case days30 = "30D"
    case days90 = "90D"
    case year1 = "1Y"

    public var id: String { rawValue }

    public var dayCount: Int {
        switch self {
        case .days7: 7
        case .days30: 30
        case .days90: 90
        case .year1: 365
        }
    }
}

public enum DashboardTab: String, Sendable, CaseIterable, Identifiable {
    case overview = "Overview"
    case projects = "Projects"
    case modelsAndQuotas = "Models & Quotas"

    public var id: String { rawValue }
}

public enum AppearanceOverride: String, Sendable, CaseIterable, Identifiable, Codable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"

    public var id: String { rawValue }
}

public enum WidgetSizePreset: String, Sendable, CaseIterable, Identifiable {
    case compact = "Compact"
    case standard = "Standard"
    case large = "Large"

    public var id: String { rawValue }

    public var dimensions: CGSize {
        switch self {
        case .compact: CGSize(width: 360, height: 224)
        case .standard: CGSize(width: 424, height: 260)
        case .large: CGSize(width: 540, height: 336)
        }
    }
}

public enum VelocityMetric: String, Sendable, CaseIterable, Identifiable {
    case apiCost = "API Equivalent"
    case totalTokens = "Total Tokens"
    case cacheSaved = "Cache Saved"
    case sessions = "Sessions"

    public var id: String { rawValue }
}

public struct DayActivity: Sendable, Identifiable, Hashable {
    public let day: String // YYYY-MM-DD (local timezone)
    public let date: Date
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreateTokens: Int64
    public let costUSD: Double
    public let cacheSavedUSD: Double
    public let claudeCostUSD: Double
    public let codexCostUSD: Double
    public let agyCostUSD: Double
    public let sessions: Int
    public let topProject: String
    public let isEstimated: Bool

    public init(
        day: String,
        date: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheCreateTokens: Int64,
        costUSD: Double,
        cacheSavedUSD: Double,
        claudeCostUSD: Double,
        codexCostUSD: Double = 0,
        agyCostUSD: Double,
        sessions: Int,
        topProject: String,
        isEstimated: Bool
    ) {
        self.day = day
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreateTokens = cacheCreateTokens
        self.costUSD = costUSD
        self.cacheSavedUSD = cacheSavedUSD
        self.claudeCostUSD = claudeCostUSD
        self.codexCostUSD = codexCostUSD
        self.agyCostUSD = agyCostUSD
        self.sessions = sessions
        self.topProject = topProject
        self.isEstimated = isEstimated
    }

    public var id: String { day }

    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens
    }

    public var activeTokens: Int64 {
        inputTokens + outputTokens
    }

    public func value(for metric: HeatmapMetric) -> Double {
        switch metric {
        case .usd: costUSD
        case .tokens: Double(totalTokens)
        case .sessions: Double(sessions)
        }
    }

    public static func empty(day: String, date: Date) -> DayActivity {
        DayActivity(
            day: day,
            date: date,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreateTokens: 0,
            costUSD: 0,
            cacheSavedUSD: 0,
            claudeCostUSD: 0,
            agyCostUSD: 0,
            sessions: 0,
            topProject: "",
            isEstimated: false
        )
    }
}

public struct DayDetailBreakdown: Sendable, Hashable {
    public let day: DayActivity
    public let projects: [ProjectStat]
    public let models: [ModelStat]
}

public struct ProjectStat: Sendable, Identifiable, Hashable {
    public let project: String
    public let totalTokens: Int64
    public let costUSD: Double
    public let cacheSavedUSD: Double
    public let claudeCostUSD: Double
    public let codexCostUSD: Double
    public let agyCostUSD: Double
    public let sessions: Int

    public init(
        project: String,
        totalTokens: Int64,
        costUSD: Double,
        cacheSavedUSD: Double,
        claudeCostUSD: Double,
        codexCostUSD: Double = 0,
        agyCostUSD: Double,
        sessions: Int
    ) {
        self.project = project
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.cacheSavedUSD = cacheSavedUSD
        self.claudeCostUSD = claudeCostUSD
        self.codexCostUSD = codexCostUSD
        self.agyCostUSD = agyCostUSD
        self.sessions = sessions
    }

    public var id: String { project }

    public var claudeShare: Double {
        guard costUSD > 0 else { return 0.5 }
        return min(1, max(0, claudeCostUSD / costUSD))
    }

    public var codexShare: Double {
        guard costUSD > 0 else { return 0 }
        return min(1, max(0, codexCostUSD / costUSD))
    }

    public var agyShare: Double {
        guard costUSD > 0 else { return 0 }
        return min(1, max(0, agyCostUSD / costUSD))
    }
}

public struct ModelStat: Sendable, Identifiable, Hashable {
    public let model: String
    public let provider: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreateTokens: Int64
    public let costUSD: Double
    public let isEstimated: Bool

    public var id: String { "\(provider):\(model)" }

    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens
    }
}

public struct QuotaItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let label: String
    public let sublabel: String
    public let provider: ProviderKind
    /// 0.0...1.0 utilization USED (0.0 = fresh/ready, 1.0 = exhausted)
    public let usedFraction: Double
    public let resetsAt: Date?
    public let fetchedAt: Date?
    public let isAvailable: Bool

    public func isExpired(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public var isExpired: Bool {
        isExpired(at: Date())
    }

    public func effectiveUsedFraction(at now: Date) -> Double {
        if !isAvailable { return 0 }
        return isExpired(at: now) ? 0 : min(1, max(0, usedFraction))
    }

    public var effectiveUsedFraction: Double {
        effectiveUsedFraction(at: Date())
    }

    public func effectiveUsedPercent(at now: Date) -> Int {
        Int((effectiveUsedFraction(at: now) * 100).rounded())
    }

    public var effectiveUsedPercent: Int {
        effectiveUsedPercent(at: Date())
    }

    public func ageMinutes(at now: Date) -> Int? {
        guard let fetchedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(fetchedAt) / 60))
    }

    public var ageMinutes: Int? {
        ageMinutes(at: Date())
    }

    public func isStale(at now: Date) -> Bool {
        guard let age = ageMinutes(at: now) else { return false }
        return age >= 60 && !isExpired(at: now)
    }

    public var isStale: Bool {
        isStale(at: Date())
    }

    public func staleLabel(at now: Date) -> String? {
        guard let age = ageMinutes(at: now), age >= 60, !isExpired(at: now) else { return nil }
        if age < 120 { return "\(age)m ago" }
        let hrs = age / 60
        if hrs < 48 { return "\(hrs)h ago" }
        return "\(hrs / 24)d ago"
    }

    public var staleLabel: String? {
        staleLabel(at: Date())
    }
}

public struct IngestionStatus: Sendable, Hashable {
    public let isBackfilling: Bool
    public let filesProcessed: Int
    public let filesTotal: Int
    public let claudeFileCount: Int
    public let codexFileCount: Int
    public let agyDBCount: Int
    public let lastDeltaMs: Double?
    public let lastUpdated: Date?

    public init(
        isBackfilling: Bool,
        filesProcessed: Int,
        filesTotal: Int,
        claudeFileCount: Int,
        codexFileCount: Int = 0,
        agyDBCount: Int,
        lastDeltaMs: Double?,
        lastUpdated: Date?
    ) {
        self.isBackfilling = isBackfilling
        self.filesProcessed = filesProcessed
        self.filesTotal = filesTotal
        self.claudeFileCount = claudeFileCount
        self.codexFileCount = codexFileCount
        self.agyDBCount = agyDBCount
        self.lastDeltaMs = lastDeltaMs
        self.lastUpdated = lastUpdated
    }

    public static let idle = IngestionStatus(
        isBackfilling: false,
        filesProcessed: 0,
        filesTotal: 0,
        claudeFileCount: 0,
        codexFileCount: 0,
        agyDBCount: 0,
        lastDeltaMs: nil,
        lastUpdated: nil
    )
}

public struct UsageSnapshot: Sendable {
    public let generatedAt: Date
    public let dailySeries: [DayActivity] // Last 365 days ordered oldest -> newest
    public let today: DayActivity
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let projects: [ProjectStat]
    public let models: [ModelStat]
    public let quotas: [QuotaItem]
    public let ingestion: IngestionStatus

    public static let empty = UsageSnapshot(
        generatedAt: Date(),
        dailySeries: [],
        today: .empty(day: "", date: Date()),
        currentStreakDays: 0,
        longestStreakDays: 0,
        projects: [],
        models: [],
        quotas: [],
        ingestion: .idle
    )
}

public enum NumberFormatting {
    public static func splitUSD(_ value: Double) -> (major: String, subCents: String) {
        let clamped = max(0, value)
        if clamped >= 1000 {
            let formatted = String(format: "%.2f", clamped)
            let parts = formatted.split(separator: ".")
            let intVal = Int(parts.first ?? "0") ?? 0
            let grouped = intVal.formatted(.number)
            return ("$\(grouped).\(parts.last ?? "00")", "")
        }
        let s = String(format: "%.4f", clamped)
        let parts = s.split(separator: ".")
        let intPart = String(parts[0])
        let frac = String(parts[1])
        let cents = String(frac.prefix(2))
        let sub = String(frac.dropFirst(2).prefix(2))
        return ("$\(intPart).\(cents)", clamped < 100 ? sub : "")
    }

    public static func compactUSD(_ value: Double) -> String {
        let v = max(0, value)
        if v >= 999.5 { return String(format: "$%.1fK", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 10 { return String(format: "$%.1f", v) }
        return String(format: "$%.2f", v)
    }

    public static func compactTokens(_ count: Int64) -> String {
        let clamped = max(0, count)
        let d = Double(clamped)
        if d >= 1_000_000_000 { return String(format: "%.2fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
        return "\(clamped)"
    }
}
