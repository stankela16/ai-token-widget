import AppKit
import SwiftUI

/// Fluidly resizable macOS 27 Desktop Widget embedded inside a single `NSGlassEffectView`.
/// Supports free drag-to-resize from the bottom-right corner (340×220 … 720×460), quick size presets,
/// hold-to-drag repositioning, tactile UI sound effects, and an unfiltered `widgetSnapshot`.
public struct DesktopWidgetView: View {
    @Bindable var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hoveredDay: DayActivity?
    @State private var isHoveringWidget = false
    @State private var isHoveringHero = false
    @State private var isHoveringExpand = false

    public init(state: AppState) {
        self.state = state
    }

    private var snap: UsageSnapshot { state.widgetSnapshot }

    /// Explicit future quota reset dates so `TimelineView(.explicit)` flips expired quotas cleanly at 0% idle CPU.
    private var quotaWakeDates: [Date] {
        let now = Date()
        return snap.quotas.compactMap { q in
            guard let r = q.resetsAt, r > now else { return nil }
            return r.addingTimeInterval(1)
        }.sorted()
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let isCompact = w < 385
            let isLarge = w >= 500
            let pad: CGFloat = isCompact ? 12 : 16

            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: isCompact ? 4 : 8) {
                    topHeaderRow(isCompact: isCompact, isLarge: isLarge)

                    Coral3DHeatmapView(
                        days: snap.dailySeries,
                        weekCount: state.widgetWeeks,
                        metric: state.heatmapMetric,
                        is3D: state.widgetIs3D,
                        compact: true,
                        onHoverDay: { day in hoveredDay = day },
                        onSelectDay: { day in state.openDashboard(focusing: day) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    bottomStatusBar(isCompact: isCompact)
                }
                .padding(pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Subtle macOS corner drag-to-resize grip (visible on hover when unlocked)
                if !state.widgetLockPosition {
                    WidgetResizeHandle(isWidgetHovered: isHoveringWidget)
                        .frame(width: 18, height: 18)
                        .padding(6)
                }
            }
        }
        .frame(
            minWidth: DesktopPanelController.minWidgetSize.width,
            maxWidth: .infinity,
            minHeight: DesktopPanelController.minWidgetSize.height,
            maxHeight: .infinity
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) {
                isHoveringWidget = hovering
            }
        }
        .onTapGesture(count: 2) {
            SoundEngine.shared.play(.click)
            state.openDashboard()
        }
        .contextMenu {
            widgetContextMenu
        }
        .preferredColorScheme(state.preferredColorScheme)
    }

    // MARK: - Header Row (Hero Metric + Streak + 2D|3D Pill + Drag Handle + Open Dashboard)

    private func topHeaderRow(isCompact: Bool, isLarge: Bool) -> some View {
        let heroSize: CGFloat = isLarge ? 24 : (isCompact ? 18 : 20)

        return HStack(alignment: .center, spacing: isCompact ? 4 : 8) {
            // Left: Live dot + clickable metric hero readout
            Button {
                SoundEngine.shared.play(.metricPop)
                withAnimation(reduceMotion ? .none : .snappy(duration: 0.25)) {
                    state.cycleMetric()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(CoralPalette.primaryAccent(for: colorScheme))
                        .symbolEffect(.pulse, value: state.livePulseCount)
                        .symbolEffectsRemoved(reduceMotion)
                        .offset(y: -2)

                    heroMetricValue(fontSize: heroSize)

                    if !isCompact {
                        Text(todayBadgeLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                Color.primary.opacity(isHoveringHero ? 0.13 : 0.07),
                                in: Capsule()
                            )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringHero = $0 }
            .help("Click to cycle metric (USD / Tokens / Sessions)")
            .accessibilityLabel("Today's usage")
            .accessibilityValue(heroAccessibilityValue)
            .accessibilityHint("Click to switch between USD, Tokens, and Sessions")

            Spacer(minLength: 4)

            // Streak pill
            if snap.currentStreakDays > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CoralPalette.primaryAccent(for: colorScheme))
                    Text("\(snap.currentStreakDays)d")
                        .font(AppTypography.monoCaption(11))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.9))
                }
                .padding(.horizontal, isCompact ? 6 : 8)
                .padding(.vertical, 4)
                .background(CoralPalette.primaryAccent(for: colorScheme).opacity(0.14), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .help("Active streak: \(snap.currentStreakDays) days (best: \(snap.longestStreakDays)d)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Active streak: \(snap.currentStreakDays) days")
            }

            // Native compact 2D | 3D switcher pill + drag handle + expand action
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    perspectiveButton("2D", active: !state.widgetIs3D) {
                        withAnimation(reduceMotion ? .none : .snappy(duration: 0.2)) {
                            state.widgetIs3D = false
                        }
                    }
                    perspectiveButton("3D", active: state.widgetIs3D) {
                        withAnimation(reduceMotion ? .none : .snappy(duration: 0.2)) {
                            state.widgetIs3D = true
                        }
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.08), in: Capsule())

                // Hold & drag handle to reposition the widget anywhere on screen (hidden when locked)
                if !state.widgetLockPosition {
                    WidgetDragHandle(isWidgetHovered: isHoveringWidget)
                        .frame(width: 24, height: 24)
                }

                // Expand to Dashboard button
                Button {
                    SoundEngine.shared.play(.click)
                    state.openDashboard()
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(isHoveringExpand ? 1.0 : (isHoveringWidget ? 0.90 : 0.65)))
                        .frame(width: 24, height: 24)
                        .background(
                            Color.primary.opacity(isHoveringExpand ? 0.18 : (isHoveringWidget ? 0.12 : 0.06)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringExpand = $0 }
                .help("Open Analytics Dashboard (⌃⌥T)")
                .accessibilityLabel("Open Dashboard")
            }
        }
    }

    @ViewBuilder
    private func heroMetricValue(fontSize: CGFloat) -> some View {
        let today = snap.today
        switch state.heatmapMetric {
        case .usd:
            let parts = NumberFormatting.splitUSD(today.costUSD)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(parts.major)
                    .font(AppTypography.heroNumber(fontSize))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText(value: today.costUSD))
                    .animation(reduceMotion ? .none : .snappy(duration: 0.3), value: today.costUSD)
                if !parts.subCents.isEmpty {
                    Text(parts.subCents)
                        .font(AppTypography.monoCaption(max(10.5, fontSize * 0.54)))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText(value: today.costUSD))
                        .animation(reduceMotion ? .none : .snappy(duration: 0.3), value: today.costUSD)
                }
            }
        case .tokens:
            Text(NumberFormatting.compactTokens(today.totalTokens))
                .font(AppTypography.heroNumber(fontSize))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText(value: Double(today.totalTokens)))
                .animation(reduceMotion ? .none : .snappy(duration: 0.3), value: today.totalTokens)
        case .sessions:
            Text("\(today.sessions)")
                .font(AppTypography.heroNumber(fontSize))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText(value: Double(today.sessions)))
                .animation(reduceMotion ? .none : .snappy(duration: 0.3), value: today.sessions)
        }
    }

    private var heroAccessibilityValue: String {
        let today = snap.today
        switch state.heatmapMetric {
        case .usd:
            return String(format: "$%.2f API equivalent today", today.costUSD)
        case .tokens:
            return "\(NumberFormatting.compactTokens(today.totalTokens)) tokens today"
        case .sessions:
            return "\(today.sessions) sessions today"
        }
    }

    private var todayBadgeLabel: String {
        switch state.heatmapMetric {
        case .usd: "TODAY · USD"
        case .tokens: "TODAY · TOK"
        case .sessions: "TODAY · SESS"
        }
    }

    private func perspectiveButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? Color.white : .secondary)
                .frame(minWidth: 26, minHeight: 18)
                .padding(.horizontal, 4)
                .background(
                    active ? CoralPalette.prominentButtonFill(for: colorScheme) : Color.clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Switch heatmap to \(title) view")
        .accessibilityLabel("\(title) view")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Bottom Bar (Hover Day Inspector OR Compact Honest Quotas)

    private func bottomStatusBar(isCompact: Bool) -> some View {
        HStack(spacing: 8) {
            if let day = hoveredDay {
                HStack(spacing: 4) {
                    Circle()
                        .fill(CoralPalette.primaryAccent(for: colorScheme))
                        .frame(width: 6, height: 6)
                    Text(shortDate(day.date))
                        .font(.system(size: 11, weight: .semibold))
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(NumberFormatting.compactUSD(day.costUSD))
                        .font(AppTypography.monoCaption(11))
                        .monospacedDigit()
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(NumberFormatting.compactTokens(day.totalTokens)) tok")
                        .font(AppTypography.monoCaption(11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if !isCompact && !day.topProject.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(day.topProject)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            } else if snap.ingestion.isBackfilling {
                let ing = snap.ingestion
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Indexing local logs (\(ing.filesProcessed)/\(ing.filesTotal))…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            } else {
                TimelineView(.explicit(quotaWakeDates)) { timeline in
                    compactQuotaStrip(at: timeline.date)
                }
                Spacer(minLength: 4)
                Text("\(state.widgetWeeks)w")
                    .font(AppTypography.monoCaption(10))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, state.widgetLockPosition ? 0 : 12)
            }
        }
        .frame(height: 18)
    }

    private func compactQuotaStrip(at now: Date) -> some View {
        let claudeQuota = snap.quotas.first(where: { $0.id == "claude-5h" })
            ?? snap.quotas.first(where: { $0.provider == .claude })
        let codexQuota = snap.quotas.first(where: { $0.id == "codex-5h" })
            ?? snap.quotas.first(where: { $0.provider == .codex })
        let agyQuota = snap.quotas.first(where: { $0.provider == .antigravity })

        return HStack(spacing: 12) {
            if let claudeQuota {
                quotaInlineBadge(claudeQuota, tint: CoralPalette.claudeAccent(for: colorScheme), at: now)
            }
            if let codexQuota {
                quotaInlineBadge(codexQuota, tint: CoralPalette.codexAccent(for: colorScheme), at: now)
            } else if let agyQuota {
                quotaInlineBadge(agyQuota, tint: CoralPalette.agyAccent(for: colorScheme), at: now)
            }
            if claudeQuota == nil && codexQuota == nil && agyQuota == nil {
                let total30d = snap.dailySeries.suffix(30).reduce(0.0) { $0 + $1.costUSD }
                Text("30d: \(NumberFormatting.compactUSD(total30d)) · \(NumberFormatting.compactTokens(snap.today.totalTokens)) today")
                    .font(AppTypography.monoCaption(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func quotaInlineBadge(_ q: QuotaItem, tint: Color, at now: Date) -> some View {
        let expired = q.isExpired(at: now)
        let pct = q.effectiveUsedPercent(at: now)
        let stale = q.staleLabel(at: now)

        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(q.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            if expired {
                Text("Ready")
                    .font(AppTypography.monoCaption(10.5))
                    .foregroundStyle(CoralPalette.cacheAccent(for: colorScheme))
            } else {
                Text("\(pct)%")
                    .font(AppTypography.monoCaption(10.5))
                    .foregroundStyle(.primary.opacity(0.9))
                    .monospacedDigit()
                if let stale {
                    Text(stale)
                        .font(AppTypography.monoCaption(10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(q.label): \(expired ? "Ready, 0 percent used" : "\(pct) percent used")")
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var widgetContextMenu: some View {
        Button("Open Analytics Dashboard") {
            SoundEngine.shared.play(.click)
            state.openDashboard()
        }
        Divider()
        Menu("Widget Size") {
            ForEach(WidgetSizePreset.allCases) { preset in
                Button("\(preset.rawValue) (\(Int(preset.dimensions.width))×\(Int(preset.dimensions.height)))") {
                    SoundEngine.shared.play(.click)
                    state.onApplyWidgetSizePreset?(preset)
                }
                .disabled(state.widgetLockPosition)
            }
        }
        Menu("Heatmap Span") {
            ForEach([8, 10, 12, 14, 16], id: \.self) { weeks in
                Button {
                    SoundEngine.shared.play(.click)
                    state.widgetWeeks = weeks
                } label: {
                    if state.widgetWeeks == weeks {
                        Label("\(weeks) weeks", systemImage: "checkmark")
                    } else {
                        Text("\(weeks) weeks")
                    }
                }
            }
        }
        Menu("Heatmap Metric") {
            ForEach(HeatmapMetric.allCases) { m in
                Button {
                    SoundEngine.shared.play(.metricPop)
                    state.heatmapMetric = m
                } label: {
                    if state.heatmapMetric == m {
                        Label(m.rawValue, systemImage: "checkmark")
                    } else {
                        Text(m.rawValue)
                    }
                }
            }
        }
        Button(state.widgetIs3D ? "Switch to 2D Flat Grid" : "Switch to 3D Isometric") {
            state.widgetIs3D.toggle()
        }
        Divider()
        Toggle("Float on Top", isOn: $state.floatOnTop)
        Toggle("Lock Position & Size", isOn: $state.widgetLockPosition)
        Toggle("Sound Effects", isOn: $state.soundEffectsEnabled)
        Menu("Appearance") {
            ForEach(AppearanceOverride.allCases) { mode in
                Button {
                    SoundEngine.shared.play(.click)
                    state.appearanceOverride = mode
                } label: {
                    if state.appearanceOverride == mode {
                        Label(mode.rawValue, systemImage: "checkmark")
                    } else {
                        Text(mode.rawValue)
                    }
                }
            }
        }
        Divider()
        Button("Refresh Local Sources") {
            SoundEngine.shared.play(.click)
            state.refreshNow()
        }
        Button("Settings…") {
            SoundEngine.shared.play(.click)
            state.onOpenSettings?()
        }
        Divider()
        Button("Quit Milkit") {
            NSApp.terminate(nil)
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Native AppKit Hold-to-Drag Handle

/// Compact 24×24 circular grip button that initiates a native 120Hz macOS `NSWindow.performDrag(with:)`
/// on first mouse-down (even when the desktop panel is inactive).
private struct WidgetDragHandle: View {
    let isWidgetHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHandleHovered = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(backgroundOpacity))

            // 3×2 tactile grip dots matching macOS HIG precision
            VStack(spacing: 2.2) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 2.2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(Color.primary.opacity(dotOpacity))
                                .frame(width: 2.2, height: 2.2)
                        }
                    }
                }
            }

            WindowDragEventCatcher(
                isHovered: $isHandleHovered,
                isDragging: $isDragging
            )
        }
        .scaleEffect(isDragging && !reduceMotion ? 0.92 : 1.0)
        .animation(reduceMotion ? .none : .snappy(duration: 0.15), value: isDragging)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.14), value: isHandleHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Move widget")
        .accessibilityHint("Press and drag to reposition the widget on your desktop")
    }

    private var backgroundOpacity: Double {
        if isDragging { return 0.22 }
        if isHandleHovered { return 0.16 }
        return isWidgetHovered ? 0.10 : 0.06
    }

    private var dotOpacity: Double {
        if isDragging || isHandleHovered { return 0.95 }
        return isWidgetHovered ? 0.80 : 0.55
    }
}

private struct WindowDragEventCatcher: NSViewRepresentable {
    @Binding var isHovered: Bool
    @Binding var isDragging: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isHovered: $isHovered, isDragging: $isDragging)
    }

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.toolTip = "Hold and drag to move widget"
        view.onHoverChanged = { [weak coordinator = context.coordinator] hovering in
            coordinator?.setHovered(hovering)
        }
        view.onDragStateChanged = { [weak coordinator = context.coordinator] dragging in
            coordinator?.setDragging(dragging)
        }
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        context.coordinator.isHovered = $isHovered
        context.coordinator.isDragging = $isDragging
    }

    @MainActor
    final class Coordinator {
        var isHovered: Binding<Bool>
        var isDragging: Binding<Bool>

        init(isHovered: Binding<Bool>, isDragging: Binding<Bool>) {
            self.isHovered = isHovered
            self.isDragging = isDragging
        }

        func setHovered(_ value: Bool) { isHovered.wrappedValue = value }
        func setDragging(_ value: Bool) { isDragging.wrappedValue = value }
    }
}

private final class DragHandleNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    private var isWindowTopmostAtPointer: Bool {
        guard let window else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isWindowTopmostAtPointer else { return }
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isWindowTopmostAtPointer else { return }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onDragStateChanged?(true)
        NSCursor.closedHand.push()
        defer {
            NSCursor.pop()
            onDragStateChanged?(false)
        }
        window.performDrag(with: event)
    }
}

// MARK: - Native AppKit Bottom-Right Corner Drag-to-Resize Handle

/// Subtle diagonal corner resize grip that appears on hover and smoothly resizes the borderless
/// `NSPanel` at 120Hz (keeping top-left corner anchored and clamping to `340×220 … 720×460`).
private struct WidgetResizeHandle: View {
    let isWidgetHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHandleHovered = false
    @State private var isResizing = false

    var body: some View {
        ZStack {
            // Subtle macOS corner resize grip marks (visible on hover / resize)
            Canvas { context, size in
                let opacity: Double = isResizing ? 0.85 : (isHandleHovered ? 0.70 : (isWidgetHovered ? 0.34 : 0.0))
                guard opacity > 0.01 else { return }
                let color = Color.primary.opacity(opacity)

                var p1 = Path()
                p1.move(to: CGPoint(x: size.width - 11, y: size.height - 3))
                p1.addLine(to: CGPoint(x: size.width - 3, y: size.height - 11))

                var p2 = Path()
                p2.move(to: CGPoint(x: size.width - 7, y: size.height - 3))
                p2.addLine(to: CGPoint(x: size.width - 3, y: size.height - 7))

                let stroke = StrokeStyle(lineWidth: 1.4, lineCap: .round)
                context.stroke(p1, with: .color(color), style: stroke)
                context.stroke(p2, with: .color(color), style: stroke)
            }

            WindowResizeEventCatcher(
                isHovered: $isHandleHovered,
                isResizing: $isResizing
            )
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.14), value: isWidgetHovered)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.12), value: isHandleHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize widget")
        .accessibilityHint("Press and drag from bottom-right corner to resize the widget")
    }
}

private struct WindowResizeEventCatcher: NSViewRepresentable {
    @Binding var isHovered: Bool
    @Binding var isResizing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isHovered: $isHovered, isResizing: $isResizing)
    }

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        view.toolTip = "Drag corner to resize widget"
        view.onHoverChanged = { [weak coordinator = context.coordinator] hovering in
            coordinator?.isHovered.wrappedValue = hovering
        }
        view.onResizeStateChanged = { [weak coordinator = context.coordinator] resizing in
            coordinator?.isResizing.wrappedValue = resizing
        }
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        context.coordinator.isHovered = $isHovered
        context.coordinator.isResizing = $isResizing
    }

    @MainActor
    final class Coordinator {
        var isHovered: Binding<Bool>
        var isResizing: Binding<Bool>

        init(isHovered: Binding<Bool>, isResizing: Binding<Bool>) {
            self.isHovered = isHovered
            self.isResizing = isResizing
        }
    }
}

private final class ResizeHandleNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onResizeStateChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    private static var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        return NSCursor.crosshair
    }

    private var isWindowTopmostAtPointer: Bool {
        guard let window else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isWindowTopmostAtPointer else { return }
        Self.resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isWindowTopmostAtPointer else { return }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startFrame = window.frame
        let minS = DesktopPanelController.minWidgetSize
        let maxS = DesktopPanelController.maxWidgetSize

        onResizeStateChanged?(true)
        Self.resizeCursor.push()
        defer {
            NSCursor.pop()
            onResizeStateChanged?(false)
        }

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .greatestFiniteMagnitude,
            mode: .eventTracking
        ) { nextEvent, stop in
            guard let nextEvent else { return }
            if nextEvent.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let cur = NSEvent.mouseLocation
            let dx = cur.x - startMouse.x
            let dy = startMouse.y - cur.y // Dragging down increases height in AppKit coordinates
            let newW = min(maxS.width, max(minS.width, (startFrame.width + dx).rounded()))
            let newH = min(maxS.height, max(minS.height, (startFrame.height + dy).rounded()))
            let newFrame = NSRect(
                x: startFrame.origin.x,
                y: startFrame.maxY - newH,
                width: newW,
                height: newH
            )
            window.setFrame(newFrame, display: true)
        }
    }
}
