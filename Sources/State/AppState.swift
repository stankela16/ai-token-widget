import AppKit
import os
import SwiftUI

@MainActor
@Observable
public final class AppState {
    private let logger = Logger(subsystem: "io.github.stankela16.milkit", category: "AppState")

    // Dashboard snapshot (respects Dashboard providerFilter & timeRange)
    public var snapshot: UsageSnapshot = .empty
    // Desktop Widget snapshot (always unfiltered All providers so Dashboard filters never corrupt Widget)
    public var widgetSnapshot: UsageSnapshot = .empty
    public var selectedDayDetail: DayDetailBreakdown?
    public var engineInitError: String?

    // Widget controls (persisted explicitly on mutation, never read inside body)
    public var heatmapMetric: HeatmapMetric {
        didSet {
            guard oldValue != heatmapMetric else { return }
            UserDefaults.standard.set(heatmapMetric.rawValue, forKey: Keys.metric)
        }
    }
    public var widgetIs3D: Bool {
        didSet {
            guard oldValue != widgetIs3D else { return }
            UserDefaults.standard.set(widgetIs3D, forKey: Keys.widgetIs3D)
        }
    }
    public var widgetWeeks: Int {
        didSet {
            guard oldValue != widgetWeeks else { return }
            UserDefaults.standard.set(widgetWeeks, forKey: Keys.widgetWeeks)
        }
    }
    public var floatOnTop: Bool {
        didSet {
            guard oldValue != floatOnTop else { return }
            UserDefaults.standard.set(floatOnTop, forKey: Keys.floatOnTop)
            onFloatOnTopChanged?(floatOnTop)
        }
    }
    public var widgetLockPosition: Bool {
        didSet {
            guard oldValue != widgetLockPosition else { return }
            UserDefaults.standard.set(widgetLockPosition, forKey: Keys.lockPosition)
            onLockPositionChanged?(widgetLockPosition)
        }
    }
    public var soundEffectsEnabled: Bool {
        didSet {
            guard oldValue != soundEffectsEnabled else { return }
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Keys.soundEnabled)
            SoundEngine.shared.isEnabled = soundEffectsEnabled
        }
    }
    public var soundVolume: Double {
        didSet {
            guard abs(oldValue - soundVolume) > 0.001 else { return }
            UserDefaults.standard.set(soundVolume, forKey: Keys.soundVolume)
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }
    public var appearanceOverride: AppearanceOverride {
        didSet {
            guard oldValue != appearanceOverride else { return }
            UserDefaults.standard.set(appearanceOverride.rawValue, forKey: Keys.appearance)
            onAppearanceChanged?(appearanceOverride)
        }
    }

    // Dashboard view state
    public var selectedTab: DashboardTab = .overview
    public var dashboardIs3D: Bool = true
    public var timeRange: TimeRangeFilter = .days30 {
        didSet {
            guard oldValue != timeRange else { return }
            reloadFilteredSnapshot()
        }
    }
    public var providerFilter: ProviderFilter = .all {
        didSet {
            guard oldValue != providerFilter else { return }
            reloadFilteredSnapshot()
        }
    }
    public var velocityMetric: VelocityMetric = .apiCost

    // Live pulse trigger for subtle FSEvents feedback
    public var livePulseCount: Int = 0
    public var isDemoMode: Bool = false {
        didSet {
            guard oldValue != isDemoMode else { return }
            clearSelectedDay()
            if isDemoMode {
                applyDemoSnapshots()
            } else {
                startEngineIfNeeded()
                reloadFilteredSnapshot()
                refreshNow()
            }
        }
    }

    // Callbacks wired by AppDelegate
    public var onOpenDashboard: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onFloatOnTopChanged: ((Bool) -> Void)?
    public var onLockPositionChanged: ((Bool) -> Void)?
    public var onApplyWidgetSizePreset: ((WidgetSizePreset) -> Void)?
    public var onAppearanceChanged: ((AppearanceOverride) -> Void)?

    private var engine: UsageEngine?
    private var started = false
    private var queryTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    private enum Keys {
        static let metric = "milkit.metric"
        static let widgetIs3D = "milkit.widgetIs3D"
        static let widgetWeeks = "milkit.widgetWeeks"
        static let floatOnTop = "milkit.floatOnTop"
        static let lockPosition = "milkit.lockPosition"
        static let soundEnabled = "milkit.soundEnabled"
        static let soundVolume = "milkit.soundVolume"
        static let appearance = "milkit.appearance"
    }

    public init() {
        let ud = UserDefaults.standard
        self.heatmapMetric = ud.string(forKey: Keys.metric).flatMap(HeatmapMetric.init(rawValue:)) ?? .usd
        self.widgetIs3D = ud.object(forKey: Keys.widgetIs3D) == nil ? true : ud.bool(forKey: Keys.widgetIs3D)
        let savedWeeks = ud.integer(forKey: Keys.widgetWeeks)
        self.widgetWeeks = [8, 10, 12, 14, 16].contains(savedWeeks) ? savedWeeks : 14
        self.floatOnTop = ud.bool(forKey: Keys.floatOnTop)
        self.widgetLockPosition = ud.bool(forKey: Keys.lockPosition)
        self.soundEffectsEnabled = ud.object(forKey: Keys.soundEnabled) == nil ? true : ud.bool(forKey: Keys.soundEnabled)
        self.soundVolume = ud.object(forKey: Keys.soundVolume) == nil ? 0.65 : ud.double(forKey: Keys.soundVolume)
        self.appearanceOverride = ud.string(forKey: Keys.appearance).flatMap(AppearanceOverride.init(rawValue:)) ?? .system

        SoundEngine.shared.isEnabled = self.soundEffectsEnabled
        SoundEngine.shared.volume = Float(self.soundVolume)

        if CommandLine.arguments.contains("--demo") {
            self.isDemoMode = true
            self.applyDemoSnapshots()
        }
    }

    private func applyDemoSnapshots() {
        let dash = DemoDataGenerator.snapshot(providerFilter: providerFilter, rangeDays: timeRange.dayCount)
        let wid = DemoDataGenerator.snapshot(providerFilter: .all, rangeDays: 30)
        self.snapshot = dash
        self.widgetSnapshot = wid
    }

    public var preferredColorScheme: ColorScheme? {
        switch appearanceOverride {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    public var dashboardHeatmapWeeks: Int {
        switch timeRange {
        case .days7, .days30, .days90: 22
        case .year1: 36
        }
    }

    public func startEngineIfNeeded() {
        guard !started else { return }
        started = true
        do {
            let eng = try UsageEngine()
            self.engine = eng
            Task { [weak self] in
                await eng.start { [weak self] dashSnap, widSnap in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isDemoMode else { return }
                        let hadBaseline = self.widgetSnapshot.today.totalTokens > 0
                        let didGrow = widSnap.today.totalTokens > self.widgetSnapshot.today.totalTokens
                        self.snapshot = dashSnap
                        self.widgetSnapshot = widSnap
                        if didGrow {
                            self.livePulseCount += 1
                            if hadBaseline && !widSnap.ingestion.isBackfilling {
                                SoundEngine.shared.play(.liveChime)
                            }
                        }
                        self.refreshSelectedDayIfOpen(using: dashSnap)
                    }
                }
            }
        } catch {
            logger.error("Failed to initialize UsageEngine: \(error.localizedDescription, privacy: .public)")
            self.engineInitError = error.localizedDescription
        }
    }

    public func cycleMetric() {
        let all = HeatmapMetric.allCases
        if let idx = all.firstIndex(of: heatmapMetric) {
            heatmapMetric = all[(idx + 1) % all.count]
        }
    }

    public func openDashboard(focusing day: DayActivity? = nil) {
        selectedTab = .overview
        if let day {
            // Ensure selected day matches current Dashboard snapshot (filtered if applicable)
            let resolved = snapshot.dailySeries.first(where: { $0.id == day.id }) ?? day
            selectDay(resolved)
        }
        onOpenDashboard?()
    }

    public func selectDay(_ day: DayActivity) {
        if isDemoMode {
            detailTask?.cancel()
            selectedDayDetail = DemoDataGenerator.dayBreakdown(for: day)
            return
        }
        guard let engine else { return }
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            let detail = await engine.dayBreakdown(for: day)
            guard !Task.isCancelled else { return }
            self?.selectedDayDetail = detail
        }
    }

    public func clearSelectedDay() {
        detailTask?.cancel()
        selectedDayDetail = nil
    }

    public func refreshNow() {
        if isDemoMode {
            applyDemoSnapshots()
            return
        }
        guard let engine else { return }
        Task { await engine.refreshNow() }
    }

    public func rebuildIndex() {
        if isDemoMode {
            applyDemoSnapshots()
            return
        }
        guard let engine else { return }
        clearSelectedDay()
        Task { await engine.rebuildIndex() }
    }

    private func reloadFilteredSnapshot() {
        if isDemoMode {
            applyDemoSnapshots()
            return
        }
        guard let engine else { return }
        let prov = providerFilter
        let days = timeRange.dayCount
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            let snap = await engine.updateQuery(provider: prov, rangeDays: days)
            guard !Task.isCancelled, let self else { return }
            self.snapshot = snap
            self.refreshSelectedDayIfOpen(using: snap)
        }
    }

    /// Keeps an open Day Breakdown synchronized with the latest provider/range snapshot and clears off-grid days.
    private func refreshSelectedDayIfOpen(using snap: UsageSnapshot) {
        guard let currentID = selectedDayDetail?.day.id, let engine else { return }
        let visibleSlots = dashboardHeatmapWeeks * 7
        let visibleDays = snap.dailySeries.suffix(visibleSlots)
        guard let updatedDay = visibleDays.first(where: { $0.id == currentID }) else {
            selectedDayDetail = nil
            return
        }
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            let detail = await engine.dayBreakdown(for: updatedDay)
            guard !Task.isCancelled else { return }
            self?.selectedDayDetail = detail
        }
    }
}
