import AppKit
import SwiftUI

/// Native macOS 27 Analytics Dashboard window with unified Liquid Glass toolbar
/// (`Overview` | `Projects` | `Models & Quotas`), full 22–36w Coral 3D Heatmap,
/// clickable Day Breakdown drawer, Coral Velocity Curve, sortable tables, and honest Live Quotas rail.
public struct DashboardView: View {
    @Bindable var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showRebuildConfirm = false
    @State private var projectSort: ProjectSortColumn = .cost
    @State private var projectSortAscending = false
    @State private var modelSort: ModelSortColumn = .cost
    @State private var modelSortAscending = false

    public init(state: AppState) {
        self.state = state
    }

    private enum ProjectSortColumn {
        case name, tokens, cacheSaved, cost
    }

    private enum ModelSortColumn {
        case name, input, output, cache, cost
    }

    private var visibleRangeDays: [DayActivity] {
        Array(state.snapshot.dailySeries.suffix(state.timeRange.dayCount))
    }

    /// Explicit future quota reset dates so `TimelineView(.explicit)` transitions expired quotas to Ready at 0% idle CPU.
    private var quotaWakeDates: [Date] {
        let now = Date()
        return state.snapshot.quotas.compactMap { q in
            guard let r = q.resetsAt, r > now else { return nil }
            return r.addingTimeInterval(1)
        }.sorted()
    }

    private var sortedProjects: [ProjectStat] {
        state.snapshot.projects.sorted { a, b in
            let asc: Bool = switch projectSort {
            case .name: a.project.localizedCaseInsensitiveCompare(b.project) == .orderedAscending
            case .tokens: a.totalTokens < b.totalTokens
            case .cacheSaved: a.cacheSavedUSD < b.cacheSavedUSD
            case .cost: a.costUSD < b.costUSD
            }
            return projectSortAscending ? asc : !asc
        }
    }

    private var sortedModels: [ModelStat] {
        state.snapshot.models.sorted { a, b in
            let asc: Bool = switch modelSort {
            case .name: a.model.localizedCaseInsensitiveCompare(b.model) == .orderedAscending
            case .input: a.inputTokens < b.inputTokens
            case .output: a.outputTokens < b.outputTokens
            case .cache: (a.cacheReadTokens + a.cacheCreateTokens) < (b.cacheReadTokens + b.cacheCreateTokens)
            case .cost: a.costUSD < b.costUSD
            }
            return modelSortAscending ? asc : !asc
        }
    }

    public var body: some View {
        Group {
            switch state.selectedTab {
            case .overview:
                overviewContent
            case .projects:
                projectsContent
            case .modelsAndQuotas:
                modelsAndQuotasContent
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            // Left-aligned section switcher (window title hidden) guarantees zero clipping at 900pt–1400pt+
            ToolbarItem(placement: .navigation) {
                Picker("Section", selection: $state.selectedTab) {
                    ForEach(DashboardTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Switch Dashboard section (⌘1 Overview · ⌘2 Projects · ⌘3 Models & Quotas)")
                .accessibilityLabel("Dashboard Section")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Range", selection: $state.timeRange) {
                    ForEach(TimeRangeFilter.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Analytics time window")
                .accessibilityLabel("Time Range")

                Picker("AI Provider", selection: $state.providerFilter) {
                    ForEach(ProviderFilter.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .help("Filter analytics by AI provider")
                .accessibilityLabel("AI Provider Filter")

                Button {
                    state.refreshNow()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh local logs and quotas (⌘R)")
                .accessibilityLabel("Refresh local logs and quotas")

                Button {
                    state.onOpenSettings?()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
        }
        .preferredColorScheme(state.preferredColorScheme)
        .confirmationDialog(
            "Rebuild Local SQLite Index?",
            isPresented: $showRebuildConfirm,
            titleVisibility: .visible
        ) {
            Button("Rebuild Index", role: .destructive) {
                state.rebuildIndex()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the cached rollup database and re-parses all local Claude Code, Codex CLI, and Antigravity logs from scratch.")
        }
    }

    // MARK: - Tab 1: Overview

    private var overviewContent: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                // Main Left Column: Hero 3D Coral Heatmap + Day Breakdown + Velocity Curve
                VStack(spacing: 16) {
                    HeroHeatmapCardView(
                        state: state,
                        visibleRangeDays: visibleRangeDays,
                        weekCount: state.dashboardHeatmapWeeks
                    )

                    if let detail = state.selectedDayDetail {
                        DayBreakdownDrawerView(detail: detail) {
                            state.clearSelectedDay()
                        }
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .top))
                        )
                    }

                    VelocityCurveView(
                        days: visibleRangeDays,
                        selectedMetric: $state.velocityMetric
                    )
                }
                .frame(maxWidth: .infinity)

                // Right Rail (consistent 280pt across Overview and Models & Quotas)
                VStack(spacing: 16) {
                    liveQuotasRailCard
                    tokenMixCard
                    topProjectsCompactCard
                }
                .frame(width: 280)
            }
            .padding(16)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.28), value: state.selectedDayDetail?.day.id)
    }

    // MARK: - Right Rail Cards

    private var liveQuotasRailCard: some View {
        TimelineView(.explicit(quotaWakeDates)) { timeline in
            let now = timeline.date
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Live Quotas")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(state.isDemoMode ? "Demo Data" : "Local · Real-time")
                        .font(AppTypography.monoCaption(10))
                        .foregroundStyle(.secondary)
                }

                if let err = state.engineInitError {
                    Text("Index error: \(err)")
                        .font(.system(size: 11))
                        .foregroundStyle(CoralPalette.primaryAccent(for: colorScheme))
                } else if state.snapshot.quotas.isEmpty {
                    Text("No local quota caches detected yet. Start a Claude Code or Codex CLI session to populate quotas.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(state.snapshot.quotas) { q in
                            quotaRow(q, at: now)
                        }
                    }
                }
            }
            .dashboardCard(padding: 16)
        }
    }

    private func quotaRow(_ q: QuotaItem, at now: Date) -> some View {
        let accent: Color = switch q.provider {
        case .claude: CoralPalette.claudeAccent(for: colorScheme)
        case .codex: CoralPalette.codexAccent(for: colorScheme)
        case .antigravity: CoralPalette.agyAccent(for: colorScheme)
        }
        let expired = q.isExpired(at: now)
        let usedFraction = q.effectiveUsedFraction(at: now)
        let usedPct = q.effectiveUsedPercent(at: now)
        let stale = q.staleLabel(at: now)
        let isStale = q.isStale(at: now)

        let segments = 20
        let lit = Int((usedFraction * Double(segments)).rounded())

        let tooltipText: String = {
            var parts = ["\(q.label) (\(q.provider.displayName))"]
            if expired {
                parts.append("Window reset — ready at 0%")
            } else {
                parts.append("\(usedPct)% used")
                if let reset = q.resetsAt {
                    parts.append("Resets \(reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                }
            }
            if let fetched = q.fetchedAt {
                parts.append("Cached \(fetched.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
            }
            return parts.joined(separator: " · ")
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                    Text(q.label)
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                if expired {
                    Text("Ready (0%)")
                        .font(AppTypography.monoCaption(11))
                        .foregroundStyle(CoralPalette.cacheAccent(for: colorScheme))
                } else {
                    Text("\(usedPct)%")
                        .font(AppTypography.monoCaption(11.5))
                        .monospacedDigit()
                        .foregroundStyle(isStale ? .secondary : .primary)
                }
            }

            // Segmented hardware LED bar (20 ticks — no unnecessary GeometryReader)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i < lit ? accent.opacity(isStale ? 0.50 : 0.95) : Color.primary.opacity(0.11))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 8)

            HStack(spacing: 8) {
                Text(q.sublabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let stale {
                    Text(stale)
                        .font(AppTypography.monoCaption(10))
                        .foregroundStyle(.secondary)
                } else if let reset = q.resetsAt, !expired {
                    HStack(spacing: 4) {
                        Text("Resets")
                        Text(reset, style: .relative)
                    }
                    .font(AppTypography.monoCaption(10))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .help(tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(q.label)
        .accessibilityValue(expired ? "Ready, 0 percent used" : "\(usedPct) percent used\(stale.map { ", cached \($0)" } ?? "")")
    }

    private var tokenMixCard: some View {
        let inputTok = visibleRangeDays.reduce(Int64(0)) { $0 + $1.inputTokens }
        let outTok = visibleRangeDays.reduce(Int64(0)) { $0 + $1.outputTokens }
        let cacheTok = visibleRangeDays.reduce(Int64(0)) { $0 + $1.cacheReadTokens + $1.cacheCreateTokens }
        let total = max(Int64(1), inputTok + outTok + cacheTok)
        let saved = visibleRangeDays.reduce(0.0) { $0 + $1.cacheSavedUSD }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Token Mix (\(state.timeRange.rawValue))")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("+\(NumberFormatting.compactUSD(saved))")
                    .font(AppTypography.monoCaption(11))
                    .foregroundStyle(CoralPalette.cacheAccent(for: colorScheme))
                    .help("Estimated API cost saved via prompt caching")
            }

            mixBarRow("Cache Read/Write", tokens: cacheTok, share: Double(cacheTok) / Double(total), color: CoralPalette.cacheAccent(for: colorScheme))
            mixBarRow("Input Prompt", tokens: inputTok, share: Double(inputTok) / Double(total), color: CoralPalette.agyAccent(for: colorScheme))
            mixBarRow("Output Gen", tokens: outTok, share: Double(outTok) / Double(total), color: CoralPalette.claudeAccent(for: colorScheme))
        }
        .dashboardCard(padding: 16)
    }

    private func mixBarRow(_ title: String, tokens: Int64, share: Double, color: Color) -> some View {
        let pct = Int((share * 100).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(NumberFormatting.compactTokens(tokens)) · \(pct)%")
                    .font(AppTypography.monoCaption(10.5))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if tokens > 0 {
                        Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(share)))
                    }
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(NumberFormatting.compactTokens(tokens)) tokens, \(pct) percent")
    }

    private var topProjectsCompactCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Projects")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HoverLinkButton(title: "See All", helpText: "View all projects in the Projects tab") {
                    state.selectedTab = .projects
                }
            }

            if state.snapshot.projects.isEmpty {
                Text("No project activity in the selected range.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(state.snapshot.projects.prefix(4)) { proj in
                        CompactProjectRow(proj: proj) {
                            state.selectedTab = .projects
                        }
                    }
                }
            }
        }
        .dashboardCard(padding: 16)
    }

    // MARK: - Tab 2: Projects (Sortable, hoverable flat single-container table)

    private var projectsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Projects · \(state.timeRange.rawValue)")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text("\(state.snapshot.projects.count) active projects")
                        .font(AppTypography.monoCaption(11))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        sortableHeader("Project", active: projectSort == .name, ascending: projectSortAscending, alignment: .leading) {
                            toggleProjectSort(.name)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Split (Claude / Codex / AGY)")
                            .font(AppTypography.monoCaption(10.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 148, alignment: .leading)

                        sortableHeader("Tokens", active: projectSort == .tokens, ascending: projectSortAscending, alignment: .trailing) {
                            toggleProjectSort(.tokens)
                        }
                        .frame(width: 96, alignment: .trailing)

                        sortableHeader("Cache Saved", active: projectSort == .cacheSaved, ascending: projectSortAscending, alignment: .trailing) {
                            toggleProjectSort(.cacheSaved)
                        }
                        .frame(width: 96, alignment: .trailing)

                        sortableHeader("API Eq.", active: projectSort == .cost, ascending: projectSortAscending, alignment: .trailing) {
                            toggleProjectSort(.cost)
                        }
                        .frame(width: 96, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    if sortedProjects.isEmpty {
                        Text("No project activity found for this period and filter.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(24)
                    } else {
                        ForEach(Array(sortedProjects.enumerated()), id: \.element.id) { idx, proj in
                            if idx > 0 { Divider().padding(.leading, 16) }
                            ProjectTableRow(proj: proj)
                        }
                    }
                }
                .dashboardCard(padding: 0)
            }
            .padding(16)
        }
    }

    // MARK: - Tab 3: Models & Quotas

    private var modelsAndQuotasContent: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                // Models breakdown flat sortable table
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Models · \(state.timeRange.rawValue)")
                            .font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Text("\(state.snapshot.models.count) models")
                            .font(AppTypography.monoCaption(11))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            sortableHeader("Model", active: modelSort == .name, ascending: modelSortAscending, alignment: .leading) {
                                toggleModelSort(.name)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            sortableHeader("Input", active: modelSort == .input, ascending: modelSortAscending, alignment: .trailing) {
                                toggleModelSort(.input)
                            }
                            .frame(width: 72, alignment: .trailing)

                            sortableHeader("Output", active: modelSort == .output, ascending: modelSortAscending, alignment: .trailing) {
                                toggleModelSort(.output)
                            }
                            .frame(width: 72, alignment: .trailing)

                            sortableHeader("Cache", active: modelSort == .cache, ascending: modelSortAscending, alignment: .trailing) {
                                toggleModelSort(.cache)
                            }
                            .frame(width: 72, alignment: .trailing)

                            sortableHeader("API Eq.", active: modelSort == .cost, ascending: modelSortAscending, alignment: .trailing) {
                                toggleModelSort(.cost)
                            }
                            .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()

                        if sortedModels.isEmpty {
                            Text("No model usage recorded for this period and filter.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(24)
                        } else {
                            ForEach(Array(sortedModels.enumerated()), id: \.element.id) { idx, m in
                                if idx > 0 { Divider().padding(.leading, 16) }
                                ModelTableRow(model: m)
                            }
                        }
                    }
                    .dashboardCard(padding: 0)
                }
                .frame(maxWidth: .infinity)

                // Right column (consistent 280pt rail): Full Quotas + Local Engine Diagnostics
                VStack(spacing: 16) {
                    liveQuotasRailCard
                    engineDiagnosticsCard
                }
                .frame(width: 280)
            }
            .padding(16)
        }
    }

    private var engineDiagnosticsCard: some View {
        let ing = state.snapshot.ingestion
        return VStack(alignment: .leading, spacing: 12) {
            Text("Local Ingestion Engine")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 8) {
                diagRow("Claude JSONL files", value: "\(ing.claudeFileCount)")
                diagRow("Codex JSONL files", value: "\(ing.codexFileCount)")
                diagRow("Antigravity SQLite DBs", value: "\(ing.agyDBCount)")
                if let ms = ing.lastDeltaMs {
                    diagRow("Last scan latency", value: String(format: "%.1f ms", ms))
                }
                diagRow("Mode", value: "FSEvents · 0% idle")
            }

            Divider()

            HStack(spacing: 8) {
                Button("Refresh Now") {
                    state.refreshNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Scan for newly written local session logs and quota files")

                Button("Rebuild Index", role: .destructive) {
                    showRebuildConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear SQLite rollup cache and re-index all local logs from scratch")
            }
        }
        .dashboardCard(padding: 16)
    }

    private func diagRow(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(AppTypography.monoCaption(11.5))
                .monospacedDigit()
        }
    }

    private func sortableHeader(
        _ title: String,
        active: Bool,
        ascending: Bool,
        alignment: Alignment,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if alignment == .trailing && active {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(AppTypography.monoCaption(10.5))
                if alignment == .leading && active {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(active ? CoralPalette.primaryAccent(for: colorScheme) : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
    }

    private func toggleProjectSort(_ col: ProjectSortColumn) {
        if projectSort == col {
            projectSortAscending.toggle()
        } else {
            projectSort = col
            projectSortAscending = (col == .name)
        }
    }

    private func toggleModelSort(_ col: ModelSortColumn) {
        if modelSort == col {
            modelSortAscending.toggle()
        } else {
            modelSort = col
            modelSortAscending = (col == .name)
        }
    }
}

// MARK: - Isolated Hero Heatmap Card (hover state stays local — zero sibling invalidation)

private struct HeroHeatmapCardView: View {
    @Bindable var state: AppState
    let visibleRangeDays: [DayActivity]
    let weekCount: Int

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredDay: DayActivity?

    var body: some View {
        let rangeCost = visibleRangeDays.reduce(0.0) { $0 + $1.costUSD }
        let rangeTokens = visibleRangeDays.reduce(Int64(0)) { $0 + $1.totalTokens }
        let parts = NumberFormatting.splitUSD(rangeCost)
        let tiers = CoralPalette.tiers(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            // Row 1: Eyebrow + Streak on left | Coral Metric Switcher + 2D/3D Toggle on right
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Text("ACTIVITY · \(weekCount) WEEKS")
                        .font(AppTypography.monoCaption(10.5))
                        .foregroundStyle(CoralPalette.primaryAccent(for: colorScheme))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if state.snapshot.currentStreakDays > 0 {
                        Label("\(state.snapshot.currentStreakDays)d streak", systemImage: "flame.fill")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(CoralPalette.primaryAccent(for: colorScheme))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    // Coral-themed capsule switcher (replaces oversized blue NSSegmentedControl)
                    HStack(spacing: 2) {
                        ForEach(HeatmapMetric.allCases) { metric in
                            let active = state.heatmapMetric == metric
                            Button {
                                SoundEngine.shared.play(.metricPop)
                                withAnimation(reduceMotion ? .none : .snappy(duration: 0.2)) {
                                    state.heatmapMetric = metric
                                }
                            } label: {
                                Text(metric.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(active ? Color.white : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        active ? CoralPalette.prominentButtonFill(for: colorScheme) : Color.clear,
                                        in: Capsule()
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Scale heatmap by \(metric.rawValue)")
                            .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .fixedSize()

                    // Prominent 2D | 3D Toggle with guaranteed >= 5.0:1 WCAG AA contrast
                    Button {
                        state.dashboardIs3D.toggle()
                    } label: {
                        Label(
                            state.dashboardIs3D ? "Back to 2D" : "View in 3D",
                            systemImage: state.dashboardIs3D ? "square.grid.3x3" : "cube"
                        )
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            CoralPalette.prominentButtonFill(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Toggle 2D / 3D isometric heatmap (⌘D)")
                    .accessibilityLabel(state.dashboardIs3D ? "Switch heatmap to 2D" : "Switch heatmap to 3D")
                }
            }

            // Row 2: Unbreakable single-line Hero KPI readout + range subtitle
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(parts.major)
                        .font(AppTypography.heroNumber(28))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.numericText(value: rangeCost))
                        .animation(reduceMotion ? .none : .snappy(duration: 0.28), value: rangeCost)
                    if !parts.subCents.isEmpty {
                        Text(parts.subCents)
                            .font(AppTypography.monoCaption(14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(format: "$%.2f API equivalent", rangeCost))

                Text("API eq. (\(state.timeRange.rawValue)) · \(NumberFormatting.compactTokens(rangeTokens)) tok")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)
            }

            Coral3DHeatmapView(
                days: state.snapshot.dailySeries,
                weekCount: weekCount,
                metric: state.heatmapMetric,
                is3D: state.dashboardIs3D,
                compact: false,
                selectedDayID: state.selectedDayDetail?.day.id,
                onHoverDay: { hoveredDay = $0 },
                onSelectDay: { day in
                    if state.selectedDayDetail?.day.id == day.id {
                        state.clearSelectedDay()
                    } else {
                        state.selectDay(day)
                    }
                }
            )
            .frame(height: 292)

            HStack(spacing: 12) {
                if let h = hoveredDay {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(CoralPalette.primaryAccent(for: colorScheme))
                            .frame(width: 6, height: 6)
                        Text(h.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("· \(NumberFormatting.compactUSD(h.costUSD)) · \(NumberFormatting.compactTokens(h.totalTokens)) tok · \(h.sessions) sessions")
                            .font(AppTypography.monoCaption(11))
                            .foregroundStyle(.secondary)
                        if !h.topProject.isEmpty {
                            Text("(\(h.topProject))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                } else {
                    Text(
                        state.dashboardIs3D
                            ? "Drag or 2-finger slide to orbit · Pinch or mouse wheel to zoom · Click tower to inspect"
                            : "Click any day square to inspect daily projects and models"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text("Less")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    ForEach(0..<tiers.count, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(tiers[idx].flat)
                            .frame(width: 11, height: 11)
                    }
                    Text("More")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Heatmap intensity scale from less to more")
            }
            .frame(height: 18)
        }
        .dashboardCard(padding: 16)
        .onChange(of: state.selectedTab) { _, _ in hoveredDay = nil }
        .onChange(of: state.timeRange) { _, _ in hoveredDay = nil }
        .onChange(of: state.providerFilter) { _, _ in hoveredDay = nil }
    }
}

// MARK: - Day Breakdown Drawer

private struct DayBreakdownDrawerView: View {
    let detail: DayDetailBreakdown
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isCloseHovered = false

    var body: some View {
        let day = detail.day
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Day Breakdown · \(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(NumberFormatting.compactUSD(day.costUSD)) API eq. · \(NumberFormatting.compactTokens(day.totalTokens)) tok · +\(NumberFormatting.compactUSD(day.cacheSavedUSD)) cache saved · \(day.sessions) sessions")
                        .font(AppTypography.monoCaption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(isCloseHovered ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close day breakdown (Esc)")
                .accessibilityLabel("Close day breakdown")
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PROJECTS")
                        .font(AppTypography.monoCaption(10))
                        .foregroundStyle(.secondary)
                    if detail.projects.isEmpty {
                        Text("No activity recorded for this day.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.projects.prefix(5)) { p in
                            HStack(spacing: 8) {
                                Text(p.project)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text(NumberFormatting.compactTokens(p.totalTokens))
                                    .font(AppTypography.monoCaption(11))
                                    .foregroundStyle(.secondary)
                                Text(NumberFormatting.compactUSD(p.costUSD))
                                    .font(AppTypography.monoCaption(11.5))
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                        if detail.projects.count > 5 {
                            Text("+\(detail.projects.count - 5) more projects")
                                .font(AppTypography.monoCaption(10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("MODELS")
                        .font(AppTypography.monoCaption(10))
                        .foregroundStyle(.secondary)
                    if detail.models.isEmpty {
                        Text("—")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.models.prefix(5)) { m in
                            let provider = ProviderKind(rawValue: m.provider)
                            let providerColor: Color = switch provider {
                            case .claude: CoralPalette.claudeAccent(for: colorScheme)
                            case .codex: CoralPalette.codexAccent(for: colorScheme)
                            case .antigravity, .none: CoralPalette.agyAccent(for: colorScheme)
                            }
                            let providerLabel: String = switch provider {
                            case .claude: "Claude"
                            case .codex: "Codex"
                            case .antigravity, .none: "AGY"
                            }
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(providerColor)
                                    .frame(width: 6, height: 6)
                                Text(m.model)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(providerLabel)
                                    .font(AppTypography.monoCaption(10))
                                    .foregroundStyle(.secondary)
                                if m.isEstimated {
                                    Text("~est.")
                                        .font(AppTypography.monoCaption(10))
                                        .foregroundStyle(.secondary)
                                        .help("Estimated API pricing from closest model family")
                                }
                                Spacer()
                                Text(NumberFormatting.compactUSD(m.costUSD))
                                    .font(AppTypography.monoCaption(11.5))
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                        if detail.models.count > 5 {
                            Text("+\(detail.models.count - 5) more models")
                                .font(AppTypography.monoCaption(10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard(padding: 16, tinted: true)
    }
}

// MARK: - Interactive Rows & Helpers

private struct HoverLinkButton: View {
    let title: String
    let helpText: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoralPalette.primaryAccent(for: colorScheme))
                .underline(isHovered)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}

private struct CompactProjectRow: View {
    let proj: ProjectStat
    let onOpenProjects: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpenProjects) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(proj.project)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(NumberFormatting.compactUSD(proj.costUSD))
                        .font(AppTypography.monoCaption(11.5))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                if proj.claudeCostUSD > 0 || proj.codexCostUSD > 0 || proj.agyCostUSD > 0 {
                    GeometryReader { geo in
                        let activeSegments = (proj.claudeCostUSD > 0 ? 1 : 0) + (proj.codexCostUSD > 0 ? 1 : 0) + (proj.agyCostUSD > 0 ? 1 : 0)
                        let usableWidth = max(0, geo.size.width - CGFloat(max(0, activeSegments - 1)) * 2)
                        HStack(spacing: 2) {
                            if proj.claudeCostUSD > 0 {
                                Capsule().fill(CoralPalette.claudeAccent(for: colorScheme))
                                    .frame(width: max(4, usableWidth * CGFloat(proj.claudeShare)))
                            }
                            if proj.codexCostUSD > 0 {
                                Capsule().fill(CoralPalette.codexAccent(for: colorScheme))
                                    .frame(width: max(4, usableWidth * CGFloat(proj.codexShare)))
                            }
                            if proj.agyCostUSD > 0 {
                                Capsule().fill(CoralPalette.agyAccent(for: colorScheme))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open Projects breakdown")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(proj.project): \(NumberFormatting.compactUSD(proj.costUSD))")
    }
}

private struct ProjectTableRow: View {
    let proj: ProjectStat

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(proj.project)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(proj.sessions) sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if proj.claudeCostUSD > 0 {
                    Capsule().fill(CoralPalette.claudeAccent(for: colorScheme))
                        .frame(width: max(4, 120 * CGFloat(proj.claudeShare)), height: 6)
                }
                if proj.codexCostUSD > 0 {
                    Capsule().fill(CoralPalette.codexAccent(for: colorScheme))
                        .frame(width: max(4, 120 * CGFloat(proj.codexShare)), height: 6)
                }
                if proj.agyCostUSD > 0 {
                    Capsule().fill(CoralPalette.agyAccent(for: colorScheme))
                        .frame(width: max(4, 120 * CGFloat(proj.agyShare)), height: 6)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 148, alignment: .leading)
            .accessibilityLabel("Claude \(Int((proj.claudeShare * 100).rounded())) percent, Codex \(Int((proj.codexShare * 100).rounded())) percent, Antigravity \(Int((proj.agyShare * 100).rounded())) percent")

            Text(NumberFormatting.compactTokens(proj.totalTokens))
                .font(AppTypography.monoCaption(12))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)

            Text("+\(NumberFormatting.compactUSD(proj.cacheSavedUSD))")
                .font(AppTypography.monoCaption(12))
                .foregroundStyle(CoralPalette.cacheAccent(for: colorScheme))
                .frame(width: 96, alignment: .trailing)

            Text(NumberFormatting.compactUSD(proj.costUSD))
                .font(AppTypography.monoCaption(12.5))
                .fontWeight(.semibold)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Project Summary") {
                let text = "\(proj.project): \(NumberFormatting.compactUSD(proj.costUSD)) API eq. · \(NumberFormatting.compactTokens(proj.totalTokens)) tokens · \(proj.sessions) sessions"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ModelTableRow: View {
    let model: ModelStat

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let provider = ProviderKind(rawValue: model.provider)
        let providerLabel: String = switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity, .none: "AGY"
        }
        let providerColor: Color = switch provider {
        case .claude: CoralPalette.claudeAccent(for: colorScheme)
        case .codex: CoralPalette.codexAccent(for: colorScheme)
        case .antigravity, .none: CoralPalette.agyAccent(for: colorScheme)
        }

        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(providerColor)
                    .frame(width: 7, height: 7)
                Text(model.model)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(providerLabel)
                    .font(AppTypography.monoCaption(10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .fixedSize()
                if model.isEstimated {
                    Text("~est.")
                        .font(AppTypography.monoCaption(10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help("Estimated API pricing from closest model family")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(NumberFormatting.compactTokens(model.inputTokens))
                .font(AppTypography.monoCaption(11.5))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(NumberFormatting.compactTokens(model.outputTokens))
                .font(AppTypography.monoCaption(11.5))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(NumberFormatting.compactTokens(model.cacheReadTokens + model.cacheCreateTokens))
                .font(AppTypography.monoCaption(11.5))
                .foregroundStyle(CoralPalette.cacheAccent(for: colorScheme))
                .frame(width: 72, alignment: .trailing)
            Text(NumberFormatting.compactUSD(model.costUSD))
                .font(AppTypography.monoCaption(12))
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Model Summary") {
                let text = "\(model.model) (\(providerLabel)): \(NumberFormatting.compactUSD(model.costUSD)) API eq. · \(NumberFormatting.compactTokens(model.totalTokens)) tokens"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.model) on \(providerLabel): \(NumberFormatting.compactUSD(model.costUSD))")
    }
}
