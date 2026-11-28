import AppKit
import SwiftUI

/// Coral `revenue-glow`-inspired velocity curve topped with 4 clickable full-cell KPI header tabs
/// (API Equivalent, Total Tokens, Cache Saved, Sessions).
/// The interactive spline canvas is isolated in a child view so pointer scrubbing never recomputes KPI totals.
public struct VelocityCurveView: View {
    public let days: [DayActivity]
    @Binding public var selectedMetric: VelocityMetric

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(days: [DayActivity], selectedMetric: Binding<VelocityMetric>) {
        self.days = days
        self._selectedMetric = selectedMetric
    }

    private var totalCost: Double { days.reduce(0) { $0 + $1.costUSD } }
    private var totalTokens: Int64 { days.reduce(0) { $0 + $1.totalTokens } }
    private var totalCacheSaved: Double { days.reduce(0) { $0 + $1.cacheSavedUSD } }
    private var totalSessions: Int { days.reduce(0) { $0 + $1.sessions } }
    private var activeDayCount: Int { days.filter { $0.totalTokens > 0 }.count }

    private var cacheHitRatio: Int {
        let totalIn = days.reduce(Int64(0)) { $0 + $1.inputTokens + $1.cacheReadTokens }
        let totalCR = days.reduce(Int64(0)) { $0 + $1.cacheReadTokens }
        guard totalIn > 0 else { return 0 }
        return Int((Double(totalCR) / Double(totalIn) * 100.0).rounded())
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 4 full-width clickable KPI tabs with uniform hit targets & hover feedback
            HStack(spacing: 0) {
                VelocityKPITab(
                    title: "API Equivalent",
                    value: NumberFormatting.compactUSD(totalCost),
                    numericValue: totalCost,
                    subtitle: "\(days.count)d total",
                    isActive: selectedMetric == .apiCost,
                    helpText: "Show daily API-equivalent spend curve"
                ) {
                    select(.apiCost)
                }

                Divider().frame(height: 44)

                VelocityKPITab(
                    title: "Total Tokens",
                    value: NumberFormatting.compactTokens(totalTokens),
                    numericValue: Double(totalTokens),
                    subtitle: "\(NumberFormatting.compactTokens(totalTokens / Int64(max(1, days.count))))/day",
                    isActive: selectedMetric == .totalTokens,
                    helpText: "Show daily total token volume curve"
                ) {
                    select(.totalTokens)
                }

                Divider().frame(height: 44)

                VelocityKPITab(
                    title: "Cache Saved",
                    value: NumberFormatting.compactUSD(totalCacheSaved),
                    numericValue: totalCacheSaved,
                    subtitle: "\(cacheHitRatio)% hit rate",
                    isActive: selectedMetric == .cacheSaved,
                    helpText: "Show daily prompt cache savings curve"
                ) {
                    select(.cacheSaved)
                }

                Divider().frame(height: 44)

                VelocityKPITab(
                    title: "Sessions",
                    value: "\(totalSessions)",
                    numericValue: Double(totalSessions),
                    subtitle: "\(activeDayCount) active days",
                    isActive: selectedMetric == .sessions,
                    helpText: "Show daily active sessions curve"
                ) {
                    select(.sessions)
                }
            }
            .background(Color.primary.opacity(0.025))

            Divider()

            VelocitySplineChart(days: days, selectedMetric: selectedMetric)
        }
        .dashboardCard(padding: 0)
    }

    private func select(_ metric: VelocityMetric) {
        SoundEngine.shared.play(.click)
        withAnimation(reduceMotion ? .none : .snappy(duration: 0.22)) {
            selectedMetric = metric
        }
    }
}

private struct VelocityKPITab: View {
    let title: String
    let value: String
    let numericValue: Double
    let subtitle: String
    let isActive: Bool
    let helpText: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let accent = CoralPalette.primaryAccent(for: colorScheme)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(AppTypography.metricNumber(18))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText(value: numericValue))
                    .animation(reduceMotion ? .none : .snappy(duration: 0.25), value: numericValue)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isActive ? accent : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                isActive
                    ? accent.opacity(0.09)
                    : (isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value), \(subtitle)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(helpText)
    }
}

private struct VelocitySplineChart: View {
    let days: [DayActivity]
    let selectedMetric: VelocityMetric

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hoveredIndex: Int?
    @State private var chartSize: CGSize = .zero

    private func value(for day: DayActivity) -> Double {
        switch selectedMetric {
        case .apiCost: day.costUSD
        case .totalTokens: Double(day.totalTokens)
        case .cacheSaved: day.cacheSavedUSD
        case .sessions: Double(day.sessions)
        }
    }

    private func formattedValue(_ v: Double) -> String {
        switch selectedMetric {
        case .apiCost: NumberFormatting.compactUSD(v)
        case .totalTokens: NumberFormatting.compactTokens(Int64(v))
        case .cacheSaved: "+\(NumberFormatting.compactUSD(v))"
        case .sessions: "\(Int(v.rounded()))"
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        let values = days.map(value(for:))
        let maxRaw = values.max() ?? 0
        let hasActivity = days.count >= 2 && maxRaw > 0.0001
        let maxV = max(maxRaw, 0.001) * 1.15
        let peakIdx = hasActivity ? values.enumerated().max(by: { $0.element < $1.element })?.offset : nil
        let strokeColor = CoralPalette.curveStroke(for: colorScheme)
        let peakColor = CoralPalette.brightPeak(for: colorScheme)
        let isDark = colorScheme == .dark
        let padX: CGFloat = 12

        // Adaptive hover pill placement: move to trailing edge when hovering left 40% so it never covers left peaks
        let pillOnTrailing: Bool = {
            guard let idx = hoveredIndex, days.count > 1 else { return false }
            return Double(idx) / Double(days.count - 1) < 0.40
        }()

        ZStack(alignment: pillOnTrailing ? .topTrailing : .topLeading) {
            if !hasActivity {
                VStack(spacing: 4) {
                    Text("No activity recorded in this period")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Switch the time range or provider filter to inspect usage velocity.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 176)
                .padding(16)
            } else {
                Canvas { context, size in
                    let padTop: CGFloat = 16
                    let padBottom: CGFloat = 20
                    let plotW = max(20, size.width - padX * 2)
                    let plotH = max(20, size.height - padTop - padBottom)
                    let stepX = plotW / CGFloat(values.count - 1)

                    let pts: [CGPoint] = values.enumerated().map { idx, val in
                        let x = padX + CGFloat(idx) * stepX
                        let norm = CGFloat(val / maxV)
                        let y = padTop + plotH * (1.0 - norm)
                        return CGPoint(x: x, y: y)
                    }

                    // Smooth cubic spline curve
                    var linePath = Path()
                    linePath.move(to: pts[0])
                    for i in 0..<(pts.count - 1) {
                        let p0 = pts[i]
                        let p1 = pts[i + 1]
                        let midX = (p0.x + p1.x) / 2.0
                        linePath.addCurve(
                            to: p1,
                            control1: CGPoint(x: midX, y: p0.y),
                            control2: CGPoint(x: midX, y: p1.y)
                        )
                    }

                    var areaPath = linePath
                    areaPath.addLine(to: CGPoint(x: pts.last!.x, y: padTop + plotH))
                    areaPath.addLine(to: CGPoint(x: pts.first!.x, y: padTop + plotH))
                    areaPath.closeSubpath()

                    // Area gradient bloom
                    let grad = Gradient(stops: [
                        .init(color: strokeColor.opacity(isDark ? 0.34 : 0.22), location: 0.0),
                        .init(color: strokeColor.opacity(isDark ? 0.06 : 0.04), location: 0.72),
                        .init(color: strokeColor.opacity(isDark ? 0.16 : 0.0), location: 1.0)
                    ])
                    context.fill(
                        areaPath,
                        with: .linearGradient(
                            grad,
                            startPoint: CGPoint(x: 0, y: padTop),
                            endPoint: CGPoint(x: 0, y: padTop + plotH)
                        )
                    )

                    // Vertical drop hairlines beneath the curve
                    let strideStep = max(1, values.count / 12)
                    for i in stride(from: 0, to: pts.count, by: strideStep) {
                        var vLine = Path()
                        vLine.move(to: pts[i])
                        vLine.addLine(to: CGPoint(x: pts[i].x, y: padTop + plotH))
                        context.stroke(vLine, with: .color(strokeColor.opacity(isDark ? 0.14 : 0.12)), lineWidth: 1)
                    }

                    // Luminous Coral spline stroke
                    var glowCtx = context
                    if isDark {
                        glowCtx.addFilter(.shadow(color: strokeColor.opacity(0.60), radius: 6))
                    }
                    glowCtx.stroke(
                        linePath,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )

                    // Highlighted orb (hovered point or peak point) — cleanly inset so halo never clips
                    let focusIdx = hoveredIndex ?? peakIdx
                    if let fIdx = focusIdx, pts.indices.contains(fIdx) {
                        let pt = pts[fIdx]
                        var cross = Path()
                        cross.move(to: CGPoint(x: pt.x, y: pt.y))
                        cross.addLine(to: CGPoint(x: pt.x, y: padTop + plotH))
                        context.stroke(cross, with: .color(strokeColor.opacity(0.65)), lineWidth: 1.2)

                        let haloRect = CGRect(x: pt.x - 9, y: pt.y - 9, width: 18, height: 18)
                        context.fill(Path(ellipseIn: haloRect), with: .color(strokeColor.opacity(0.28)))

                        let orbRect = CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: orbRect), with: .color(isDark ? peakColor : strokeColor))
                        context.stroke(Path(ellipseIn: orbRect), with: .color(.white), lineWidth: 1.5)
                    }

                    // Bottom date ticks (start, mid, end — >= 10pt readable contrast)
                    let labelIndices = [0, pts.count / 2, pts.count - 1]
                    for li in Set(labelIndices) where days.indices.contains(li) {
                        let x = pts[li].x
                        let anchorX = min(max(x, 28), size.width - 28)
                        context.draw(
                            Text(shortDate(days[li].date))
                                .font(AppTypography.monoCaption(10))
                                .foregroundStyle(.secondary),
                            at: CGPoint(x: anchorX, y: size.height - 6)
                        )
                    }
                }
                .frame(height: 176)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { chartSize = proxy.size }
                            .onChange(of: proxy.size) { _, s in chartSize = s }
                    }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let plotW = max(10, chartSize.width - padX * 2)
                        guard days.count >= 2 else { return }
                        let norm = max(0, min(1, (loc.x - padX) / plotW))
                        let idx = Int((norm * Double(days.count - 1)).rounded())
                        hoveredIndex = max(0, min(days.count - 1, idx))
                    case .ended:
                        hoveredIndex = nil
                    }
                }
                .onDisappear {
                    hoveredIndex = nil
                }
                .onChange(of: days) { _, _ in
                    hoveredIndex = nil
                }

                if let idx = hoveredIndex, days.indices.contains(idx) {
                    let item = days[idx]
                    HStack(spacing: 8) {
                        Circle()
                            .fill(CoralPalette.curveStroke(for: colorScheme))
                            .frame(width: 6, height: 6)
                        Text(shortDate(item.date))
                            .font(.system(size: 11, weight: .semibold))
                        Text(formattedValue(value(for: item)))
                            .font(AppTypography.monoCaption(11))
                            .monospacedDigit()
                            .foregroundStyle(CoralPalette.primaryAccent(for: colorScheme))
                        if !item.topProject.isEmpty {
                            Text("· \(item.topProject)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background {
                        if reduceTransparency {
                            Capsule().fill(Color(nsColor: .windowBackgroundColor))
                        } else {
                            Capsule().fill(.regularMaterial)
                        }
                    }
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(selectedMetric.rawValue) daily velocity chart")
        .accessibilityValue(hasActivity ? "Peak \(formattedValue(maxRaw)) across \(days.count) days" : "No activity recorded")
    }
}
