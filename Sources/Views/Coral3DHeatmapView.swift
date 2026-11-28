import AppKit
import SwiftUI

/// Sticky 3D orbit & zoom camera rig with smooth damping while dragging/pinching/scrolling and
/// critically-damped spring return on explicit Reset (`↺` button or double-click). Auto-pauses at
/// `0.0%` idle CPU both when resting at origin AND while parked at any custom angle or zoom level.
@MainActor
private final class HeatmapOrbitRig {
    var yaw: Double = 0.0           // radians (-2.88 ... +2.88, ~±165°)
    var pitchAdd: Double = 0.0      // ratio offset (-0.14 ... +0.42, up to ~65° bird's-eye)
    var zoom: Double = 1.0          // scale multiplier (0.65 ... 2.60)
    var panX: Double = 0.0          // screen-pt horizontal pan (used when zoomed > 1.0)
    var panY: Double = 0.0          // screen-pt vertical pan (used when zoomed > 1.0)

    var targetYaw: Double = 0.0
    var targetPitchAdd: Double = 0.0
    var targetZoom: Double = 1.0
    var targetPanX: Double = 0.0
    var targetPanY: Double = 0.0

    var velYaw: Double = 0.0
    var velPitch: Double = 0.0
    var velZoom: Double = 0.0
    var velPanX: Double = 0.0
    var velPanY: Double = 0.0

    var isInteracting: Bool = false
    var isResettingToOrigin: Bool = false
    private var lastTick: Date?

    static let maxYaw: Double = 2.88       // ~165° left/right
    static let minPitchAdd: Double = -0.14 // low dramatic angle
    static let maxPitchAdd: Double = 0.42  // high bird's-eye angle (~65°)
    static let minZoom: Double = 0.65      // comfortable overview zoom-out
    static let maxZoom: Double = 2.60      // close-up inspection zoom-in

    var isOffsetFromRest: Bool {
        abs(targetYaw) > 0.025 ||
        abs(targetPitchAdd) > 0.02 ||
        abs(targetZoom - 1.0) > 0.015 ||
        abs(targetPanX) > 1.0 ||
        abs(targetPanY) > 1.0
    }

    var isZoomed: Bool {
        abs(targetZoom - 1.0) > 0.015
    }

    var zoomPercent: Int {
        Int((targetZoom * 100.0).rounded())
    }

    func applyDelta(dx: CGFloat, dy: CGFloat) {
        isInteracting = true
        isResettingToOrigin = false
        let yawSens = 0.0115
        let pitchSens = 0.0044
        targetYaw = max(-Self.maxYaw, min(Self.maxYaw, targetYaw + Double(dx) * yawSens))
        targetPitchAdd = max(Self.minPitchAdd, min(Self.maxPitchAdd, targetPitchAdd + Double(dy) * pitchSens))
    }

    /// Multiplicative cursor-anchored zoom (pinch, ⌘/⌥+scroll, or +/- button steps).
    func applyZoom(factor: Double, anchor: CGPoint?, canvasSize: CGSize, continuous: Bool) {
        guard factor.isFinite, factor > 0.01 else { return }
        if continuous {
            isInteracting = true
        }
        isResettingToOrigin = false

        let oldZoom = targetZoom
        var newZoom = max(Self.minZoom, min(Self.maxZoom, oldZoom * factor))
        // Subtle magnetic snap right onto 100% when stepping through 1.0 via buttons
        if !continuous && abs(newZoom - 1.0) < 0.06 {
            newZoom = 1.0
        }
        let actualRatio = newZoom / max(0.01, oldZoom)
        targetZoom = newZoom

        if let anchor, canvasSize.width > 10, canvasSize.height > 10 {
            let baseX = Double(canvasSize.width / 2.0)
            let baseY = Double(canvasSize.height / 2.0)
            let curCenterX = baseX + targetPanX
            let curCenterY = baseY + targetPanY
            targetPanX += (Double(anchor.x) - curCenterX) * (1.0 - actualRatio)
            targetPanY += (Double(anchor.y) - curCenterY) * (1.0 - actualRatio)
        } else {
            targetPanX *= actualRatio
            targetPanY *= actualRatio
        }
        clampPan(canvasSize: canvasSize)
    }

    /// Smoothly pans the zoomed-in 3D canvas (Shift/Option + Drag).
    func applyPan(dx: CGFloat, dy: CGFloat, canvasSize: CGSize) {
        guard targetZoom > 1.01 else { return }
        isInteracting = true
        isResettingToOrigin = false
        targetPanX += Double(dx)
        targetPanY += Double(dy)
        clampPan(canvasSize: canvasSize)
    }

    private func clampPan(canvasSize: CGSize) {
        let excess = max(0.0, targetZoom - 1.0)
        let maxX = Double(canvasSize.width) * 0.48 * excess
        let maxY = Double(canvasSize.height) * 0.48 * excess
        targetPanX = max(-maxX, min(maxX, targetPanX))
        targetPanY = max(-maxY, min(maxY, targetPanY))
    }

    /// Parks camera smoothly at its current rotated/zoomed target so the user can hover & click freely.
    func finishInteraction() {
        isInteracting = false
    }

    /// Smoothly springs camera back to the resting hero angle `(0, 0)` and `100%` zoom.
    func resetToOrigin() {
        isInteracting = false
        isResettingToOrigin = true
        targetYaw = 0.0
        targetPitchAdd = 0.0
        targetZoom = 1.0
        targetPanX = 0.0
        targetPanY = 0.0
    }

    /// Advances physics one frame; returns `true` when settled cleanly at target.
    func step(to now: Date) -> Bool {
        let dt: Double
        if let last = lastTick {
            dt = min(0.033, max(0.001, now.timeIntervalSince(last)))
        } else {
            dt = 1.0 / 120.0
        }
        lastTick = now

        if isResettingToOrigin {
            // Smooth Apple critically-damped spring back to hero origin & 100% zoom
            let stiffness = 140.0
            let damping = 22.0

            let accYaw = -stiffness * (yaw - targetYaw) - damping * velYaw
            velYaw += accYaw * dt
            yaw += velYaw * dt

            let accPitch = -stiffness * (pitchAdd - targetPitchAdd) - damping * velPitch
            velPitch += accPitch * dt
            pitchAdd += velPitch * dt

            let accZoom = -stiffness * (zoom - targetZoom) - damping * velZoom
            velZoom += accZoom * dt
            zoom = max(0.4, zoom + velZoom * dt)

            let accPanX = -stiffness * (panX - targetPanX) - damping * velPanX
            velPanX += accPanX * dt
            panX += velPanX * dt

            let accPanY = -stiffness * (panY - targetPanY) - damping * velPanY
            velPanY += accPanY * dt
            panY += velPanY * dt

            if abs(yaw) < 0.0008 && abs(velYaw) < 0.004 &&
               abs(pitchAdd) < 0.0008 && abs(velPitch) < 0.004 &&
               abs(zoom - 1.0) < 0.0008 && abs(velZoom) < 0.004 &&
               abs(panX) < 0.25 && abs(velPanX) < 1.0 &&
               abs(panY) < 0.25 && abs(velPanY) < 1.0 {
                snapToRest()
                return true
            }
            return false
        } else {
            // Silky exponential follow during gesture + quick settle when fingers/mouse lift
            let rate = isInteracting ? 24.0 : 18.0
            let follow = 1.0 - exp(-dt * rate)
            let prevYaw = yaw
            let prevPitch = pitchAdd
            let prevZoom = zoom
            let prevPanX = panX
            let prevPanY = panY

            yaw += (targetYaw - yaw) * follow
            pitchAdd += (targetPitchAdd - pitchAdd) * follow
            zoom += (targetZoom - zoom) * follow
            panX += (targetPanX - panX) * follow
            panY += (targetPanY - panY) * follow

            velYaw = (yaw - prevYaw) / dt * 0.25
            velPitch = (pitchAdd - prevPitch) / dt * 0.25
            velZoom = (zoom - prevZoom) / dt * 0.25
            velPanX = (panX - prevPanX) / dt * 0.25
            velPanY = (panY - prevPanY) / dt * 0.25

            if !isInteracting &&
               abs(yaw - targetYaw) < 0.0006 &&
               abs(pitchAdd - targetPitchAdd) < 0.0006 &&
               abs(zoom - targetZoom) < 0.0006 &&
               abs(panX - targetPanX) < 0.2 &&
               abs(panY - targetPanY) < 0.2 {
                snapToTarget()
                return true
            }
            return false
        }
    }

    func resetTiming() {
        lastTick = nil
    }

    func snapToTarget() {
        yaw = targetYaw
        pitchAdd = targetPitchAdd
        zoom = targetZoom
        panX = targetPanX
        panY = targetPanY
        velYaw = 0
        velPitch = 0
        velZoom = 0
        velPanX = 0
        velPanY = 0
        lastTick = nil
    }

    func snapToRest() {
        yaw = 0
        pitchAdd = 0
        zoom = 1.0
        panX = 0
        panY = 0
        targetYaw = 0
        targetPitchAdd = 0
        targetZoom = 1.0
        targetPanX = 0
        targetPanY = 0
        velYaw = 0
        velPitch = 0
        velZoom = 0
        velPanX = 0
        velPanY = 0
        isInteracting = false
        isResettingToOrigin = false
        lastTick = nil
    }
}

/// High-craft GPU SwiftUI `Canvas` implementing the 2D ↔ 3D isometric prism heatmap
/// in `Primer Web coral-0`:
/// - Airy `~29°` architectural isometric geometry (`78%` cell width = crisp 22% gaps between towers)
///   so back rows remain legible even at rest.
/// - **Sticky 3D Orbit**: rotate freely with 2 fingers on trackpad or mouse drag (`yaw ±165°`, `pitch` to `~65°` bird's-eye);
///   the map stays parked where you leave it so you can hover & click every single historical day cleanly!
/// - **1-click `↺` Reset / Double-click** smoothly springs the camera back to hero rest (`0.0%` idle CPU).
/// - **Floating Callout Badge** directly above the hovered tower (`Nov 12 · $86.5`) with clean warm Coral highlight (no white roof, no dimming other towers).
public struct Coral3DHeatmapView: View {
    public let days: [DayActivity]
    public let weekCount: Int
    public let metric: HeatmapMetric
    public let is3D: Bool
    public let compact: Bool
    public let selectedDayID: String?
    public let onHoverDay: (DayActivity?) -> Void
    public let onSelectDay: (DayActivity) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var morphFrom: Double
    @State private var morphTo: Double
    @State private var morphStart: Date = .distantPast
    @State private var morphDuration: Double = 0.72
    @State private var isMorphing = false
    @State private var isOrbitAnimating = false
    @State private var isCameraModified = false
    @State private var zoomPercent: Int = 100
    @State private var isHoveringHeatmap = false
    @State private var isHoveringHUD = false
    @State private var morphSettleTask: Task<Void, Never>?
    @State private var orbitSettleTask: Task<Void, Never>?
    @State private var orbitRig = HeatmapOrbitRig()
    @State private var hoveredCellKey: String?
    @State private var focusedCellIndex: Int?
    @State private var canvasSize: CGSize = .zero
    @State private var cachedCells: [GridCell]

    public init(
        days: [DayActivity],
        weekCount: Int,
        metric: HeatmapMetric,
        is3D: Bool,
        compact: Bool = false,
        selectedDayID: String? = nil,
        onHoverDay: @escaping (DayActivity?) -> Void = { _ in },
        onSelectDay: @escaping (DayActivity) -> Void = { _ in }
    ) {
        let clampedWeeks = max(4, weekCount)
        self.days = days
        self.weekCount = clampedWeeks
        self.metric = metric
        self.is3D = is3D
        self.compact = compact
        self.selectedDayID = selectedDayID
        self.onHoverDay = onHoverDay
        self.onSelectDay = onSelectDay

        let initialMorph = is3D ? 1.0 : 0.0
        self._morphFrom = State(initialValue: initialMorph)
        self._morphTo = State(initialValue: initialMorph)
        self._cachedCells = State(initialValue: Self.buildCells(days: days, weekCount: clampedWeeks, metric: metric))
    }

    private struct GridCell: Identifiable, Equatable {
        let id: String
        let week: Int
        let dayOfWeek: Int // Strictly 0 = Mon ... 6 = Sun
        let diag: Int
        let tier: Int      // 0..4
        let microLabel: String
        let activity: DayActivity
    }

    private static func formatMicroLabel(activity: DayActivity, metric: HeatmapMetric) -> String {
        switch metric {
        case .usd:
            let v = activity.costUSD
            guard v > 0.005 else { return "" }
            if v < 0.95 { return "<1" }
            if v < 9.95 {
                let tenths = Int((v * 10.0).rounded())
                return (tenths % 10 == 0) ? "\(tenths / 10)" : String(format: "%.1f", Double(tenths) / 10.0)
            }
            if v < 999.5 { return "\(Int(v.rounded()))" }
            if v < 9_950 {
                let k10 = Int((v / 100.0).rounded())
                return (k10 % 10 == 0) ? "\(k10 / 10)K" : String(format: "%.1fK", Double(k10) / 10.0)
            }
            return "\(Int((v / 1_000.0).rounded()))K"

        case .tokens:
            let tok = activity.totalTokens
            guard tok > 0 else { return "" }
            let d = Double(tok)
            if d < 1_000 { return "\(tok)" }
            if d < 999_500 { return "\(Int((d / 1_000.0).rounded()))K" }
            if d < 9_950_000 {
                let m10 = Int((d / 100_000.0).rounded())
                return (m10 % 10 == 0) ? "\(m10 / 10)M" : String(format: "%.1fM", Double(m10) / 10.0)
            }
            if d < 999_500_000 { return "\(Int((d / 1_000_000.0).rounded()))M" }
            let b10 = Int((d / 100_000_000.0).rounded())
            return (b10 % 10 == 0) ? "\(b10 / 10)B" : String(format: "%.1fB", Double(b10) / 10.0)

        case .sessions:
            let s = activity.sessions
            guard s > 0 else { return "" }
            return s < 1_000 ? "\(s)" : "\(Int((Double(s) / 1_000.0).rounded()))K"
        }
    }

    private static func buildCells(days: [DayActivity], weekCount: Int, metric: HeatmapMetric) -> [GridCell] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayWeekday = (cal.component(.weekday, from: today) + 5) % 7
        guard let thisMonday = cal.date(byAdding: .day, value: -todayWeekday, to: today),
              let startMonday = cal.date(byAdding: .day, value: -(weekCount - 1) * 7, to: thisMonday) else {
            return []
        }

        var byDay: [String: DayActivity] = Dictionary(minimumCapacity: days.count)
        for d in days { byDay[d.day] = d }

        let totalDays = (weekCount - 1) * 7 + todayWeekday + 1
        var slotActivities: [(week: Int, dow: Int, activity: DayActivity)] = []
        slotActivities.reserveCapacity(totalDays)

        for offset in 0..<totalDays {
            guard let date = cal.date(byAdding: .day, value: offset, to: startMonday) else { continue }
            let (dayKey, _) = LocalDateFormatting.dayAndHour(from: date)
            let act = byDay[dayKey] ?? .empty(day: dayKey, date: date)
            slotActivities.append((offset / 7, offset % 7, act))
        }

        let nonZero = slotActivities.map { $0.activity.value(for: metric) }.filter { $0 > 0.0001 }.sorted()
        let refMax: Double
        if nonZero.isEmpty {
            refMax = 1.0
        } else {
            let p92Idx = min(nonZero.count - 1, Int(Double(nonZero.count - 1) * 0.92))
            refMax = max(nonZero[p92Idx], 0.01)
        }

        func tier(for value: Double) -> Int {
            guard value > 0.0001 else { return 0 }
            let ratio = min(1.0, value / refMax)
            if ratio < 0.20 { return 1 }
            if ratio < 0.48 { return 2 }
            if ratio < 0.78 { return 3 }
            return 4
        }

        var raw: [GridCell] = []
        raw.reserveCapacity(slotActivities.count)
        for slot in slotActivities {
            let act = slot.activity
            let cellTier = tier(for: act.value(for: metric))
            raw.append(GridCell(
                id: act.day.isEmpty ? "\(slot.week)_\(slot.dow)" : act.day,
                week: slot.week,
                dayOfWeek: slot.dow,
                diag: slot.week + slot.dow,
                tier: cellTier,
                microLabel: cellTier > 0 ? formatMicroLabel(activity: act, metric: metric) : "",
                activity: act
            ))
        }
        return raw.sorted { a, b in
            if a.diag != b.diag { return a.diag < b.diag }
            return a.week < b.week
        }
    }

    private func morphProgress(at now: Date) -> Double {
        let elapsed = now.timeIntervalSince(morphStart)
        if elapsed >= morphDuration {
            return morphTo
        }
        let t = max(0, min(1, elapsed / max(0.01, morphDuration)))
        return morphFrom + (morphTo - morphFrom) * t
    }

    private func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func calloutLabel(for activity: DayActivity) -> String {
        let dateStr = activity.date.formatted(.dateTime.month(.abbreviated).day())
        let valueStr: String = switch metric {
        case .usd: NumberFormatting.compactUSD(activity.costUSD)
        case .tokens: NumberFormatting.compactTokens(activity.totalTokens)
        case .sessions: "\(activity.sessions) sess"
        }
        return "\(dateStr) · \(valueStr)"
    }

    private var accessibilitySummary: String {
        let activeCount = cachedCells.filter { $0.tier > 0 }.count
        let modeText = is3D ? "3D isometric view" : "2D calendar view"
        return "\(modeText), \(weekCount) weeks, \(activeCount) active days"
    }

    public var body: some View {
        let cells = cachedCells
        let maxDiag = Double(max(1, (weekCount - 1) + 6))
        let tiers = CoralPalette.tiers(for: colorScheme)
        let shadowColor = CoralPalette.shadowTint(for: colorScheme)
        let isDark = colorScheme == .dark
        let focusedKey = focusedCellIndex.flatMap { cells.indices.contains($0) ? cells[$0].id : nil }
        let activeHoverID = hoveredCellKey ?? focusedKey
        let needsLoop = isMorphing || isOrbitAnimating

        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !needsLoop)) { timeline in
                let p = morphProgress(at: timeline.date)
                let _ = {
                    if isOrbitAnimating {
                        _ = orbitRig.step(to: timeline.date)
                    }
                }()
                let easeP = easeInOutCubic(p)
                let yaw = orbitRig.yaw * easeP
                let pitchAdd = orbitRig.pitchAdd * easeP
                let zoom = CGFloat(1.0 + (orbitRig.zoom - 1.0) * easeP)
                let pan = CGPoint(x: orbitRig.panX * easeP, y: orbitRig.panY * easeP)

                Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, size in
                    let geom = LayoutGeometry(
                        size: size,
                        weekCount: weekCount,
                        compact: compact,
                        cells: cells,
                        yaw: yaw,
                        pitchAdd: pitchAdd,
                        zoom: zoom,
                        pan: pan
                    )

                    // 1. Soft isometric ground shadow (blooms gently as board tilts into 3D)
                    let shadowAlpha = easeP * easeP
                    if shadowAlpha > 0.01 {
                        var shadowCtx = context
                        shadowCtx.opacity = shadowAlpha
                        shadowCtx.addFilter(.blur(radius: compact ? 14 : 22))
                        let shadowW = min(size.width * 1.6, geom.isoSpanWidth * 0.94)
                        let shadowRect = CGRect(
                            x: geom.isoCenterX - shadowW / 2.0,
                            y: geom.isoCenterY + geom.isoHeight * 0.14,
                            width: shadowW,
                            height: max(22, geom.isoHeight * 0.34)
                        )
                        shadowCtx.fill(Path(ellipseIn: shadowRect), with: .color(shadowColor))
                    }

                    // 2. Calendar-accurate 2D weekday labels (Mon / Wed / Fri) fading out as prisms rise
                    if !compact {
                        let lblAlpha = 1.0 - easeInOutCubic(min(1, p / 0.38))
                        if lblAlpha > 0.02 {
                            let lblColor = Color.secondary.opacity(0.85 * lblAlpha)
                            for (label, row) in [("M", 0), ("W", 2), ("F", 4)] {
                                let y = geom.flatOriginY + CGFloat(row) * geom.flatPitch + geom.flatCell * 0.5
                                context.draw(
                                    Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(lblColor),
                                    at: CGPoint(x: max(12, geom.flatOriginX - 16), y: y)
                                )
                            }
                        }
                    }

                    // 3. Dynamically painter-sorted cells by rotated camera depth (exact 360° occlusion!)
                    let drawOrder: [GridCell]
                    if abs(yaw) > 0.002 {
                        drawOrder = cells.sorted { a, b in
                            let da = geom.rotatedDepth(week: a.week, day: a.dayOfWeek)
                            let db = geom.rotatedDepth(week: b.week, day: b.dayOfWeek)
                            if abs(da - db) > 0.0001 { return da < db }
                            return a.week < b.week
                        }
                    } else {
                        drawOrder = cells
                    }

                    var hoveredCalloutTarget: (anchor: CGPoint, activity: DayActivity)?
                    let useContinuousMorph = !reduceMotion && p > 0.001 && p < 0.999
                    let morphFrame = useContinuousMorph ? geom.morphFrame(t: CGFloat(easeP), yaw: yaw) : nil

                    /// Continuous directional side-wall shade using true outward normal of clockwise screen-space quads.
                    /// Calibrated so at resting isometric (`yaw = 0`, `pitch = 0.50`) left face = 0.78 and right face = 0.60,
                    /// guaranteeing zero lighting flip between morph, rest, and 360° orbit.
                    @inline(__always)
                    func sideShadeFactor(edgeDX: CGFloat, edgeDY: CGFloat) -> Double {
                        let len = max(0.001, hypot(edgeDX, edgeDY))
                        let nx = Double(edgeDY / len) // outward normal X for clockwise quad in Y-down coordinates
                        return min(0.82, max(0.56, 0.69 - nx * 0.20125))
                    }

                    let show2DMicroLabels = geom.flatCell >= 16.5
                    let baseMicroFontSize = min(10.5, max(7.5, geom.flatCell * 0.39))

                    func drawMicroLabel(for cell: GridCell, at pt: CGPoint, alpha: Double) {
                        guard show2DMicroLabels, alpha > 0.02, !cell.microLabel.isEmpty else { return }
                        let textColor: Color
                        if isDark {
                            textColor = (cell.tier <= 2)
                                ? Color.white.opacity(0.95 * alpha)
                                : CoralPalette.c900.color.opacity(0.92 * alpha)
                        } else {
                            textColor = (cell.tier <= 2)
                                ? CoralPalette.c900.color.opacity(0.90 * alpha)
                                : Color.white.opacity(0.96 * alpha)
                        }
                        let maxW = geom.flatCell - 2.0
                        var resolved = context.resolve(
                            Text(cell.microLabel)
                                .font(.system(size: baseMicroFontSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(textColor)
                        )
                        var measured = resolved.measure(in: size)
                        if measured.width > maxW {
                            let scaledSize = max(6.6, baseMicroFontSize * (maxW / max(1.0, measured.width)))
                            resolved = context.resolve(
                                Text(cell.microLabel)
                                    .font(.system(size: scaledSize, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(textColor)
                            )
                            measured = resolved.measure(in: size)
                            guard measured.width <= geom.flatCell - 0.5 else { return }
                        }
                        context.draw(resolved, at: pt, anchor: .center)
                    }

                    for cell in drawOrder {
                        let isHovered = (activeHoverID == cell.id) && !orbitRig.isInteracting && !isMorphing
                        let isSelected = (selectedDayID == cell.id)
                        let palette = tiers[cell.tier]

                        if let frame = morphFrame {
                            // Continuous single-geometry 3D camera tilt (90° overhead 2D square ↔ 29° isometric prism)
                            let waveDelay = (Double(cell.diag) / maxDiag) * 0.18
                            let extT = easeInOutCubic(min(1, max(0, (p - 0.16 - waveDelay) / (0.84 - waveDelay * 0.5))))
                            let baseH = geom.tierHeight(cell.tier)
                            let h = baseH * CGFloat(extT)

                            let center = frame.center(week: cell.week, day: cell.dayOfWeek, midWeek: geom.midWeek, midDay: geom.midDay)
                            let verts = frame.quadVertices(at: center)
                            let topVerts = h > 0.05 ? verts.map { CGPoint(x: $0.x, y: $0.y - h) } : verts

                            // Shaded front-facing side walls fade & rise seamlessly using exact same directional formula as rest
                            if h > 0.08 {
                                let wallAlpha = min(1.0, Double(h / 1.5))
                                var wallCtx = context
                                wallCtx.opacity = wallAlpha
                                for i in 0..<4 {
                                    let next = (i + 1) % 4
                                    let pA = verts[i]
                                    let pB = verts[next]
                                    let edgeDX = pB.x - pA.x
                                    guard edgeDX < -0.001 else { continue }

                                    let shadeFactor = sideShadeFactor(edgeDX: edgeDX, edgeDY: pB.y - pA.y)

                                    var sidePath = Path()
                                    sidePath.move(to: topVerts[i])
                                    sidePath.addLine(to: topVerts[next])
                                    sidePath.addLine(to: pB)
                                    sidePath.addLine(to: pA)
                                    sidePath.closeSubpath()

                                    wallCtx.fill(sidePath, with: .color(palette.raw.scaled(shadeFactor).color))
                                }
                            }

                            let topPath = Self.roundedQuadPath(topVerts, radius: frame.cornerRadius)
                            if isDark && cell.tier == 4 && extT > 0.02 {
                                var glowCtx = context
                                let glowColor = CoralPalette.c300.color.opacity(0.38 * extT)
                                glowCtx.addFilter(.shadow(color: glowColor, radius: compact ? 4 : 6))
                                glowCtx.fill(topPath, with: .color(palette.top))
                            } else {
                                context.fill(topPath, with: .color(palette.top))
                            }
                            if isDark && cell.tier >= 3 && extT > 0.02 {
                                context.stroke(topPath, with: .color(.white.opacity(0.22 * extT)), lineWidth: 0.5)
                            }
                            if p < 0.22 {
                                let lblFade = 1.0 - easeInOutCubic(min(1.0, p / 0.20))
                                drawMicroLabel(for: cell, at: center, alpha: lblFade)
                            }
                            continue
                        }

                        let alpha2D = reduceMotion ? (1.0 - p) : (p <= 0.001 ? 1.0 : 0.0)
                        let alpha3D = reduceMotion ? p : (p >= 0.999 ? 1.0 : 0.0)

                        // Resting 2D rounded square (or Reduce Motion crossfade)
                        if alpha2D > 0.01 {
                            let flatPt = geom.flatCenter(week: cell.week, day: cell.dayOfWeek)
                            let lift: CGFloat = (isHovered || isSelected) ? 2.0 : 0
                            let rect = CGRect(
                                x: flatPt.x - geom.flatCell / 2,
                                y: flatPt.y - geom.flatCell / 2 - lift,
                                width: geom.flatCell,
                                height: geom.flatCell
                            )
                            let rr = Path(roundedRect: rect, cornerRadius: max(2.5, geom.flatCell * 0.22), style: .continuous)
                            var ctx2D = context
                            ctx2D.opacity = alpha2D
                            ctx2D.fill(rr, with: .color(palette.flat))
                            if isHovered || isSelected {
                                let rim = isDark ? CoralPalette.c200.color : CoralPalette.c700.color
                                ctx2D.stroke(rr, with: .color(rim), lineWidth: 1.4)
                            }
                            drawMicroLabel(
                                for: cell,
                                at: CGPoint(x: rect.midX, y: rect.midY),
                                alpha: alpha2D
                            )
                            if isHovered && alpha3D <= 0.5 {
                                hoveredCalloutTarget = (CGPoint(x: flatPt.x, y: rect.minY), cell.activity)
                            }
                        }

                        // Resting 3D rotated isometric prism (or Reduce Motion crossfade)
                        if alpha3D > 0.01 {
                            let baseH = geom.tierHeight(cell.tier)
                            let lift: CGFloat = isHovered ? geom.hoverLift : (isSelected ? geom.selectLift : 0)
                            let h = max(1.5, baseH) + lift * CGFloat(alpha3D)
                            let center = geom.isoCenter(week: cell.week, day: cell.dayOfWeek)

                            let verts = geom.diamondVertices(at: center) // [N, E, S, W] clockwise
                            let topVerts = verts.map { CGPoint(x: $0.x, y: $0.y - h) }

                            var ctx3D = context
                            ctx3D.opacity = alpha3D

                            // Draw front-facing side quads (edges moving right-to-left: pB.x < pA.x)
                            for i in 0..<4 {
                                let next = (i + 1) % 4
                                let pA = verts[i]
                                let pB = verts[next]
                                let edgeDX = pB.x - pA.x
                                guard edgeDX < -0.001 else { continue }

                                let shadeFactor = sideShadeFactor(edgeDX: edgeDX, edgeDY: pB.y - pA.y)

                                var sidePath = Path()
                                sidePath.move(to: topVerts[i])
                                sidePath.addLine(to: topVerts[next])
                                sidePath.addLine(to: pB)
                                sidePath.addLine(to: pA)
                                sidePath.closeSubpath()

                                let sideRGB = isHovered
                                    ? palette.raw.scaled(min(1.0, shadeFactor * 1.12))
                                    : palette.raw.scaled(shadeFactor)
                                ctx3D.fill(sidePath, with: .color(sideRGB.color))
                            }

                            // Top face diamond — stays in its own warm Coral palette (zero white roof!)
                            var topPath = Path()
                            topPath.move(to: topVerts[0])
                            topPath.addLine(to: topVerts[1])
                            topPath.addLine(to: topVerts[2])
                            topPath.addLine(to: topVerts[3])
                            topPath.closeSubpath()

                            let topFillColor: Color
                            if isHovered {
                                if cell.tier == 0 {
                                    topFillColor = isDark ? CoralPalette.c700.color.opacity(0.80) : CoralPalette.c200.color
                                } else {
                                    topFillColor = palette.raw.scaled(isDark ? 1.10 : 1.08).color
                                }
                            } else {
                                topFillColor = palette.top
                            }

                            if isDark && (cell.tier == 4 || isHovered) {
                                var glowCtx = ctx3D
                                let glowColor = isHovered ? CoralPalette.c300.color.opacity(0.55) : CoralPalette.c300.color.opacity(0.38)
                                glowCtx.addFilter(.shadow(color: glowColor, radius: compact ? 4 : 6))
                                glowCtx.fill(topPath, with: .color(topFillColor))
                            } else {
                                ctx3D.fill(topPath, with: .color(topFillColor))
                            }

                            if isHovered || isSelected {
                                let rimColor = isDark ? CoralPalette.c200.color.opacity(0.88) : CoralPalette.c700.color.opacity(0.88)
                                ctx3D.stroke(topPath, with: .color(rimColor), lineWidth: isHovered ? 1.2 : 1.0)
                            } else if isDark && cell.tier >= 3 {
                                ctx3D.stroke(topPath, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
                            }

                            if isHovered && alpha3D > 0.5 {
                                let topMostY = min(min(topVerts[0].y, topVerts[1].y), min(topVerts[2].y, topVerts[3].y))
                                hoveredCalloutTarget = (CGPoint(x: center.x, y: topMostY), cell.activity)
                            }
                        }
                    }

                    // 4. Crisp Floating Data Callout directly above the hovered tower (always topmost in Z-order)
                    if let callout = hoveredCalloutTarget {
                        let labelText = calloutLabel(for: callout.activity)
                        let resolved = context.resolve(
                            Text(labelText)
                                .font(.system(size: compact ? 10.5 : 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isDark ? Color.white : Color.black.opacity(0.92))
                        )
                        let textSize = resolved.measure(in: size)
                        let pillW = textSize.width + 16
                        let pillH: CGFloat = compact ? 20 : 22
                        let stemH: CGFloat = 10

                        // Keep callout & anchor strictly inside Canvas bounds (even when zoomed in)
                        let anchorX = min(max(callout.anchor.x, 6), size.width - 6)
                        let anchorY = min(max(callout.anchor.y, 6), size.height - 6)
                        let pillCenterX = min(max(anchorX, pillW / 2 + 6), size.width - pillW / 2 - 6)
                        let rawPillBottom = anchorY - stemH
                        let pillTopY = max(4, rawPillBottom - pillH)
                        let pillRect = CGRect(
                            x: pillCenterX - pillW / 2,
                            y: pillTopY,
                            width: pillW,
                            height: pillH
                        )

                        let accent = CoralPalette.primaryAccent(for: colorScheme)

                        // Connecting stem + tiny anchor dot on the tower roof
                        if anchorY > pillRect.maxY + 2 {
                            var stem = Path()
                            stem.move(to: CGPoint(x: anchorX, y: anchorY))
                            stem.addLine(to: CGPoint(x: anchorX, y: pillRect.maxY))
                            context.stroke(stem, with: .color(accent.opacity(0.78)), lineWidth: 1.0)
                        }
                        let dotRect = CGRect(x: anchorX - 2, y: anchorY - 2, width: 4, height: 4)
                        context.fill(Path(ellipseIn: dotRect), with: .color(accent))

                        // High-contrast floating pill with subtle shadow & border
                        let pillPath = Path(roundedRect: pillRect, cornerRadius: pillH / 2, style: .continuous)
                        var pillShadowCtx = context
                        pillShadowCtx.addFilter(.shadow(color: Color.black.opacity(isDark ? 0.45 : 0.18), radius: 5, y: 2))
                        pillShadowCtx.fill(
                            pillPath,
                            with: .color(isDark ? Color(red: 0.13, green: 0.12, blue: 0.13).opacity(0.95) : Color.white.opacity(0.96))
                        )
                        context.stroke(pillPath, with: .color(accent.opacity(0.55)), lineWidth: 0.9)
                        context.draw(resolved, at: CGPoint(x: pillRect.midX, y: pillRect.midY))
                    }
                }
                .clipped()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { canvasSize = proxy.size }
                            .onChange(of: proxy.size) { _, newSize in canvasSize = newSize }
                    }
                )
                .overlay {
                    HeatmapOrbitEventCatcher(
                        allowVerticalTwoFingerOrbit: compact,
                        is3DActive: is3D,
                        onHoverMove: { pt in
                            if !isHoveringHeatmap {
                                isHoveringHeatmap = true
                            }
                            guard !isMorphing, !orbitRig.isInteracting, !isHoveringHUD else {
                                clearHoverState()
                                return
                            }
                            let curYaw = orbitRig.yaw * easeP
                            let curPitch = orbitRig.pitchAdd * easeP
                            let curZoom = CGFloat(1.0 + (orbitRig.zoom - 1.0) * easeP)
                            let curPan = CGPoint(x: orbitRig.panX * easeP, y: orbitRig.panY * easeP)
                            let hit = hitTest(
                                point: pt,
                                cells: cells,
                                size: canvasSize,
                                progress: p,
                                yaw: curYaw,
                                pitchAdd: curPitch,
                                zoom: curZoom,
                                pan: curPan
                            )
                            if hit?.id != hoveredCellKey {
                                hoveredCellKey = hit?.id
                                if hit != nil {
                                    SoundEngine.shared.play(.hoverTick)
                                }
                                onHoverDay(hit?.activity)
                            }
                        },
                        onHoverExit: { leftBounds in
                            clearHoverState()
                            if leftBounds && isHoveringHeatmap {
                                isHoveringHeatmap = false
                            }
                        },
                        onClick: { pt in
                            let currentP = morphProgress(at: Date())
                            let eP = easeInOutCubic(currentP)
                            if let hit = hitTest(
                                point: pt,
                                cells: cells,
                                size: canvasSize,
                                progress: currentP,
                                yaw: orbitRig.yaw * eP,
                                pitchAdd: orbitRig.pitchAdd * eP,
                                zoom: CGFloat(1.0 + (orbitRig.zoom - 1.0) * eP),
                                pan: CGPoint(x: orbitRig.panX * eP, y: orbitRig.panY * eP)
                            ) {
                                SoundEngine.shared.play(.click)
                                onSelectDay(hit.activity)
                            }
                        },
                        onDoubleClick: {
                            if isCameraModified {
                                resetOrbitToOrigin()
                                return true
                            }
                            return false
                        },
                        onOrbitDelta: { dx, dy in
                            guard is3D else { return }
                            clearHoverState()
                            orbitSettleTask?.cancel()
                            orbitRig.applyDelta(dx: dx, dy: dy)
                            syncCameraHUDState()
                            startOrbitLoopIfNeeded()
                        },
                        onPanDelta: { dx, dy in
                            guard is3D, orbitRig.targetZoom > 1.01 else { return false }
                            clearHoverState()
                            orbitSettleTask?.cancel()
                            orbitRig.applyPan(dx: dx, dy: dy, canvasSize: canvasSize)
                            syncCameraHUDState()
                            startOrbitLoopIfNeeded()
                            return true
                        },
                        onZoomFactor: { factor, anchor in
                            guard is3D else { return }
                            clearHoverState()
                            orbitSettleTask?.cancel()
                            orbitRig.applyZoom(factor: factor, anchor: anchor, canvasSize: canvasSize, continuous: true)
                            syncCameraHUDState()
                            startOrbitLoopIfNeeded()
                        },
                        onSmartMagnify: { anchor in
                            guard is3D else { return }
                            SoundEngine.shared.play(.click)
                            if orbitRig.isZoomed {
                                applyZoomStep(targetFactor: 1.0 / max(0.1, orbitRig.targetZoom), anchor: nil)
                            } else {
                                applyZoomStep(targetFactor: 1.65, anchor: anchor)
                            }
                        },
                        onOrbitEnd: {
                            settleStickyOrbit()
                        }
                    )
                }
            }

            // Discreet macOS Camera HUD pill (− / zoom% / + / ↺ Reset): visible on hover or whenever transformed
            if is3D && (isHoveringHeatmap || isCameraModified) {
                cameraHUD(isDark: isDark)
                    .padding(4)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topLeading)))
            }
        }
        .onHover { hovering in
            isHoveringHeatmap = hovering
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.16), value: isCameraModified)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.16), value: isHoveringHeatmap)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { stepFocusedDay(by: -1); return .handled }
        .onKeyPress(.rightArrow) { stepFocusedDay(by: 1); return .handled }
        .onKeyPress(.upArrow) { stepFocusedDay(by: -7); return .handled }
        .onKeyPress(.downArrow) { stepFocusedDay(by: 7); return .handled }
        .onKeyPress(.return) { activateFocusedDay(); return .handled }
        .onKeyPress(.space) { activateFocusedDay(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in
            guard is3D else { return .ignored }
            stepZoom(inward: true)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "-_")) { _ in
            guard is3D else { return .ignored }
            stepZoom(inward: false)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in
            guard is3D && isCameraModified else { return .ignored }
            resetOrbitToOrigin()
            return .handled
        }
        .onChange(of: days) { _, newDays in
            rebuildCache(days: newDays, weekCount: weekCount, metric: metric)
        }
        .onChange(of: weekCount) { _, newWeeks in
            clearHoverState()
            rebuildCache(days: days, weekCount: newWeeks, metric: metric)
        }
        .onChange(of: metric) { _, newMetric in
            rebuildCache(days: days, weekCount: weekCount, metric: newMetric)
        }
        .onChange(of: is3D) { _, newValue in
            clearHoverState()
            if !newValue && isCameraModified {
                resetOrbitToOrigin(silent: true)
            }
            SoundEngine.shared.play(newValue ? .morph3D : .morph2D)
            let now = Date()
            let duration = reduceMotion ? 0.18 : 0.62
            morphFrom = morphProgress(at: now)
            morphTo = newValue ? 1.0 : 0.0
            morphDuration = duration
            morphStart = now
            isMorphing = true
            morphSettleTask?.cancel()
            morphSettleTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int((duration + 0.06) * 1000)))
                guard !Task.isCancelled else { return }
                isMorphing = false
            }
        }
        .onDisappear {
            morphSettleTask?.cancel()
            orbitSettleTask?.cancel()
            isMorphing = false
            isOrbitAnimating = false
            isCameraModified = false
            zoomPercent = 100
            isHoveringHeatmap = false
            isHoveringHUD = false
            orbitRig.snapToRest()
            clearHoverState()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coral Activity Heatmap")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(
            compact
                ? "Drag or two-finger slide to orbit, click widget then pinch on trackpad or use Command or Option scroll or mouse wheel to zoom, Shift-drag to pan when zoomed, and double-click to reset"
                : "Drag or two-finger slide to orbit, pinch on trackpad or scroll mouse wheel to zoom, Shift-drag to pan when zoomed, and double-click to reset"
        )
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Compact Floating 3D Camera Controls (− / Zoom% / + / ↺ Reset)

    @ViewBuilder
    private func cameraHUD(isDark: Bool) -> some View {
        let canZoomOut = zoomPercent > Int((HeatmapOrbitRig.minZoom * 100).rounded()) + 1
        let canZoomIn = zoomPercent < Int((HeatmapOrbitRig.maxZoom * 100).rounded()) - 1
        let zoomOutHelp = compact
            ? "Zoom out (click widget then pinch, ⌘/⌥-scroll, mouse wheel, or −)"
            : "Zoom out (pinch, mouse wheel, or −)"
        let zoomInHelp = compact
            ? "Zoom in (click widget then pinch, ⌘/⌥-scroll, mouse wheel, or +)"
            : "Zoom in (pinch, mouse wheel, or +)"

        HStack(spacing: 2) {
            CameraHUDButton(
                isEnabled: canZoomOut,
                helpText: zoomOutHelp,
                accessibilityLabel: "Zoom out 3D heatmap",
                action: { stepZoom(inward: false) }
            ) {
                Image(systemName: "minus")
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 20, height: 20)
            }

            if zoomPercent != 100 {
                CameraHUDButton(
                    isEnabled: true,
                    helpText: "Reset zoom to 100%",
                    accessibilityLabel: "Zoom level \(zoomPercent) percent, click to reset zoom",
                    action: {
                        SoundEngine.shared.play(.hoverTick)
                        applyZoomStep(targetFactor: 1.0 / max(0.1, orbitRig.targetZoom), anchor: nil)
                    }
                ) {
                    Text("\(zoomPercent)%")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .frame(height: 20)
                }
            }

            CameraHUDButton(
                isEnabled: canZoomIn,
                helpText: zoomInHelp,
                accessibilityLabel: "Zoom in 3D heatmap",
                action: { stepZoom(inward: true) }
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 20, height: 20)
            }

            if isCameraModified {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 2)

                CameraHUDButton(
                    isEnabled: true,
                    helpText: "Reset 3D angle & zoom (or double-click map)",
                    accessibilityLabel: "Reset 3D camera angle and zoom",
                    action: { resetOrbitToOrigin() }
                ) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9.5, weight: .semibold))
                        if !compact {
                            Text("Reset")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                    }
                    .padding(.horizontal, compact ? 4 : 6)
                    .frame(height: 20)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor).opacity(isDark ? 0.84 : 0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
        .contentShape(Capsule())
        .onHover { hovering in
            isHoveringHUD = hovering
            if hovering {
                clearHoverState()
            }
        }
        .onDisappear {
            isHoveringHUD = false
        }
    }

    // MARK: - Sticky Orbit & Zoom Settle / Explicit Spring Reset (0.0% Idle CPU)

    private func syncCameraHUDState() {
        let modified = orbitRig.isOffsetFromRest
        if modified != isCameraModified {
            isCameraModified = modified
        }
        let pct = orbitRig.zoomPercent
        if pct != zoomPercent {
            zoomPercent = pct
        }
    }

    private func startOrbitLoopIfNeeded() {
        if !isOrbitAnimating {
            orbitRig.resetTiming()
            isOrbitAnimating = true
        }
    }

    private func stepZoom(inward: Bool) {
        SoundEngine.shared.play(.hoverTick)
        applyZoomStep(targetFactor: inward ? 1.28 : (1.0 / 1.28), anchor: nil)
    }

    private func applyZoomStep(targetFactor: Double, anchor: CGPoint?) {
        clearHoverState()
        orbitRig.applyZoom(factor: targetFactor, anchor: anchor, canvasSize: canvasSize, continuous: false)
        syncCameraHUDState()
        startOrbitLoopIfNeeded()
        settleStickyOrbit()
    }

    private func settleStickyOrbit() {
        orbitRig.finishInteraction()
        syncCameraHUDState()
        guard isOrbitAnimating else { return }
        orbitSettleTask?.cancel()
        orbitSettleTask = Task { @MainActor in
            // Let exponential follow finish settling cleanly at parked angle/zoom, then pause TimelineView (0% CPU)
            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else { return }
            if !orbitRig.isInteracting && !orbitRig.isResettingToOrigin {
                orbitRig.snapToTarget()
                isOrbitAnimating = false
            }
        }
    }

    private func resetOrbitToOrigin(silent: Bool = false) {
        if !silent {
            SoundEngine.shared.play(.click)
        }
        clearHoverState()
        isCameraModified = false
        zoomPercent = 100
        orbitRig.resetToOrigin()
        orbitRig.resetTiming()
        isOrbitAnimating = true
        orbitSettleTask?.cancel()
        orbitSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if !orbitRig.isInteracting {
                orbitRig.snapToRest()
                isOrbitAnimating = false
            }
        }
    }

    private func rebuildCache(days: [DayActivity], weekCount: Int, metric: HeatmapMetric) {
        let updated = Self.buildCells(days: days, weekCount: weekCount, metric: metric)
        cachedCells = updated
        if let hoveredKey = hoveredCellKey {
            if let refreshed = updated.first(where: { $0.id == hoveredKey }) {
                onHoverDay(refreshed.activity)
            } else {
                clearHoverState()
            }
        }
    }

    private func clearHoverState() {
        if hoveredCellKey != nil {
            hoveredCellKey = nil
            onHoverDay(nil)
        }
    }

    private func stepFocusedDay(by delta: Int) {
        guard !cachedCells.isEmpty else { return }
        let chronological = cachedCells.sorted { ($0.week * 7 + $0.dayOfWeek) < ($1.week * 7 + $1.dayOfWeek) }
        let currentChronIdx: Int
        if let idx = focusedCellIndex, cachedCells.indices.contains(idx) {
            let currentID = cachedCells[idx].id
            currentChronIdx = chronological.firstIndex(where: { $0.id == currentID }) ?? (chronological.count - 1)
        } else {
            currentChronIdx = chronological.count - 1
        }
        let nextChronIdx = max(0, min(chronological.count - 1, currentChronIdx + delta))
        let targetID = chronological[nextChronIdx].id
        if let painterIdx = cachedCells.firstIndex(where: { $0.id == targetID }) {
            focusedCellIndex = painterIdx
            onHoverDay(cachedCells[painterIdx].activity)
        }
    }

    private func activateFocusedDay() {
        guard let idx = focusedCellIndex, cachedCells.indices.contains(idx) else { return }
        SoundEngine.shared.play(.click)
        onSelectDay(cachedCells[idx].activity)
    }

    /// Reverse depth-order exact rotated & zoomed 3D prism hit test across all 360° camera angles.
    private func hitTest(
        point: CGPoint,
        cells: [GridCell],
        size: CGSize,
        progress: Double,
        yaw: Double,
        pitchAdd: Double,
        zoom: CGFloat,
        pan: CGPoint
    ) -> GridCell? {
        guard size.width > 10, size.height > 10 else { return nil }
        let geom = LayoutGeometry(
            size: size,
            weekCount: weekCount,
            compact: compact,
            cells: cells,
            yaw: yaw,
            pitchAdd: pitchAdd,
            zoom: zoom,
            pan: pan
        )
        let isIn3D = progress > 0.5

        let ordered: [GridCell]
        if isIn3D && abs(yaw) > 0.002 {
            ordered = cells.sorted { a, b in
                geom.rotatedDepth(week: a.week, day: a.dayOfWeek) > geom.rotatedDepth(week: b.week, day: b.dayOfWeek)
            }
        } else {
            ordered = Array(cells.reversed())
        }

        for cell in ordered {
            if isIn3D {
                let c = geom.isoCenter(week: cell.week, day: cell.dayOfWeek)
                let h = geom.tierHeight(cell.tier)
                guard geom.prismBoundingRect(center: c, height: h).contains(point) else { continue }
                let verts = geom.diamondVertices(at: c)
                let topVerts = verts.map { CGPoint(x: $0.x, y: $0.y - h) }

                if Self.pointInQuad(point, topVerts[0], topVerts[1], topVerts[2], topVerts[3]) {
                    return cell
                }
                for i in 0..<4 {
                    let next = (i + 1) % 4
                    guard (verts[next].x - verts[i].x) < -0.001 else { continue }
                    if Self.pointInQuad(point, topVerts[i], topVerts[next], verts[next], verts[i]) {
                        return cell
                    }
                }
            } else {
                let c = geom.flatCenter(week: cell.week, day: cell.dayOfWeek)
                let half = geom.flatPitch / 2
                let bounds = CGRect(x: c.x - half, y: c.y - half, width: geom.flatPitch, height: geom.flatPitch)
                if bounds.contains(point) {
                    return cell
                }
            }
        }
        return nil
    }

    private static func pointInQuad(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ u: CGPoint, _ v: CGPoint, _ pt: CGPoint) -> CGFloat {
            (v.x - u.x) * (pt.y - u.y) - (v.y - u.y) * (pt.x - u.x)
        }
        let c1 = cross(a, b, p)
        let c2 = cross(b, c, p)
        let c3 = cross(c, d, p)
        let c4 = cross(d, a, p)
        let hasNeg = (c1 < 0) || (c2 < 0) || (c3 < 0) || (c4 < 0)
        let hasPos = (c1 > 0) || (c2 > 0) || (c3 > 0) || (c4 > 0)
        return !(hasNeg && hasPos)
    }

    private static func roundedQuadPath(_ pts: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard pts.count == 4 else { return path }
        if radius <= 0.15 {
            path.move(to: pts[0])
            path.addLine(to: pts[1])
            path.addLine(to: pts[2])
            path.addLine(to: pts[3])
            path.closeSubpath()
            return path
        }
        let start = CGPoint(x: (pts[3].x + pts[0].x) * 0.5, y: (pts[3].y + pts[0].y) * 0.5)
        path.move(to: start)
        path.addArc(tangent1End: pts[0], tangent2End: pts[1], radius: radius)
        path.addArc(tangent1End: pts[1], tangent2End: pts[2], radius: radius)
        path.addArc(tangent1End: pts[2], tangent2End: pts[3], radius: radius)
        path.addArc(tangent1End: pts[3], tangent2End: pts[0], radius: radius)
        path.closeSubpath()
        return path
    }

    // MARK: - Airy ~29° 360° Rotated Isometric Layout Geometry

    private struct LayoutGeometry {
        let flatCell: CGFloat
        let flatPitch: CGFloat
        let flatOriginX: CGFloat
        let flatOriginY: CGFloat

        let midWeek: CGFloat
        let midDay: CGFloat
        let isoStepX: CGFloat
        let isoPitchRatio: CGFloat
        let cosYaw: CGFloat
        let sinYaw: CGFloat
        let eW: CGPoint
        let eD: CGPoint
        let isoCenterX: CGFloat
        let isoCenterY: CGFloat
        let isoHeight: CGFloat
        let isoSpanWidth: CGFloat
        let maxTowerHeight: CGFloat
        let hoverLift: CGFloat
        let selectLift: CGFloat

        init(
            size: CGSize,
            weekCount: Int,
            compact: Bool,
            cells: [GridCell],
            yaw: Double,
            pitchAdd: Double,
            zoom: CGFloat,
            pan: CGPoint
        ) {
            let wCount = CGFloat(weekCount)
            let dCount: CGFloat = 7.0
            self.midWeek = (wCount - 1.0) / 2.0
            self.midDay = (dCount - 1.0) / 2.0

            // 1. Flat 2D calendar geometry centered in bounds
            let padX: CGFloat = compact ? 6 : 32
            let padY: CGFloat = compact ? 6 : 16
            let availW = max(40, size.width - padX * 2)
            let availH = max(40, size.height - padY * 2)
            let pitchByW = availW / wCount
            let pitchByH = availH / dCount
            self.flatPitch = min(pitchByW, pitchByH)
            self.flatCell = max(4, flatPitch * 0.80)
            let totalFlatW = wCount * flatPitch
            let totalFlatH = dCount * flatPitch
            self.flatOriginX = (size.width - totalFlatW) / 2 + (flatPitch - flatCell) / 2
            self.flatOriginY = (size.height - totalFlatH) / 2 + (flatPitch - flatCell) / 2

            // 2. Airy ~29° resting elevation (baseRatio = 0.50) + crisp 78% column width (22% breathing gaps!)
            let baseRatio: CGFloat = 0.50
            let spanUnits = (wCount - 1) + (dCount - 1) + 2.0
            let isoMarginX: CGFloat = compact ? 6 : 16
            let maxStepByW = (size.width - isoMarginX * 2) / spanUnits
            let maxStepByH = (size.height * (compact ? 0.72 : 0.70)) / (spanUnits * baseRatio)
            let stepX = max(4.0, min(maxStepByW, maxStepByH))
            let activeRatio = max(0.32, min(0.92, baseRatio + CGFloat(pitchAdd)))

            // Gentle scale compensation when looking steeply top-down so bottom diamond stays inside frame
            let pitchScaleComp: CGFloat = 1.0 - max(0, activeRatio - baseRatio) * 0.38
            let effStepX = stepX * pitchScaleComp * zoom

            self.isoStepX = effStepX
            self.isoPitchRatio = activeRatio
            self.cosYaw = CGFloat(cos(yaw))
            self.sinYaw = CGFloat(sin(yaw))

            // 78% column fill leaves crisp 22% visual channels between every tower & row
            let halfUnit = effStepX * 0.78 * 0.5
            self.eW = CGPoint(
                x: halfUnit * (cosYaw - sinYaw),
                y: halfUnit * (sinYaw + cosYaw) * activeRatio
            )
            self.eD = CGPoint(
                x: halfUnit * (-cosYaw - sinYaw),
                y: halfUnit * (-sinYaw + cosYaw) * activeRatio
            )

            let liftScale = min(1.5, max(0.75, zoom))
            self.hoverLift = (compact ? 5.0 : 7.0) * liftScale
            self.selectLift = (compact ? 3.0 : 5.0) * liftScale
            self.isoSpanWidth = spanUnits * effStepX
            self.isoHeight = ((wCount - 1) + (dCount - 1)) * effStepX * activeRatio
            self.isoCenterX = size.width / 2.0 + pan.x

            let baseElevationAngle = asin(min(0.95, Double(baseRatio)))
            let activeElevationAngle = asin(min(0.95, Double(activeRatio)))
            let verticalForeshorten = CGFloat(cos(activeElevationAngle) / max(0.25, cos(baseElevationAngle)))

            // Balanced architectural tower height so tall front peaks never swallow back rows
            let rawTowerMax = min(size.height * (compact ? 0.28 : 0.29), stepX * 3.0)
            let baseHoverLift: CGFloat = compact ? 5.0 : 7.0

            func relativeTowerHeight(_ tier: Int, cap: CGFloat) -> CGFloat {
                switch tier {
                case 0: max(1.5, cap * (3.0 / 96.0))
                case 1: cap * (19.0 / 96.0)
                case 2: cap * (38.0 / 96.0)
                case 3: cap * (64.0 / 96.0)
                default: cap
                }
            }

            let halfHBase = (stepX * 0.78) * baseRatio
            var minRelY: CGFloat = .greatestFiniteMagnitude
            var maxRelY: CGFloat = -.greatestFiniteMagnitude
            for cell in cells {
                let u = CGFloat(cell.week) - midWeek
                let v = CGFloat(cell.dayOfWeek) - midDay
                let baseY = (u + v) * stepX * baseRatio
                let topY = baseY - halfHBase - relativeTowerHeight(cell.tier, cap: rawTowerMax) - baseHoverLift
                let botY = baseY + halfHBase
                if topY < minRelY { minRelY = topY }
                if botY > maxRelY { maxRelY = botY }
            }
            if minRelY > maxRelY {
                minRelY = -isoHeight / 2
                maxRelY = isoHeight / 2
            }

            let availVisualH = max(40, size.height - 14.0)
            let totalVisualH = maxRelY - minRelY
            let baseTowerCap: CGFloat
            let baseCenterY: CGFloat
            if totalVisualH > availVisualH {
                baseTowerCap = max(14, rawTowerMax - (totalVisualH - availVisualH))
                var adjMinY: CGFloat = .greatestFiniteMagnitude
                var adjMaxY: CGFloat = -.greatestFiniteMagnitude
                for cell in cells {
                    let u = CGFloat(cell.week) - midWeek
                    let v = CGFloat(cell.dayOfWeek) - midDay
                    let baseY = (u + v) * stepX * baseRatio
                    let topY = baseY - halfHBase - relativeTowerHeight(cell.tier, cap: baseTowerCap) - baseHoverLift
                    let botY = baseY + halfHBase
                    if topY < adjMinY { adjMinY = topY }
                    if botY > adjMaxY { adjMaxY = botY }
                }
                baseCenterY = (size.height / 2.0) - (adjMinY + adjMaxY) / 2.0 + 4.0
            } else {
                baseTowerCap = rawTowerMax
                baseCenterY = (size.height / 2.0) - (minRelY + maxRelY) / 2.0 + 4.0
            }
            self.isoCenterY = baseCenterY + pan.y
            self.maxTowerHeight = max(8, baseTowerCap * pitchScaleComp * verticalForeshorten * zoom)
        }

        struct MorphFrame {
            let cosA: CGFloat
            let sinA: CGFloat
            let gridScale: CGFloat
            let pitch: CGFloat
            let centerX: CGFloat
            let centerY: CGFloat
            let eW: CGPoint
            let eD: CGPoint
            let cornerRadius: CGFloat

            func center(week: Int, day: Int, midWeek: CGFloat, midDay: CGFloat) -> CGPoint {
                let u = CGFloat(week) - midWeek
                let v = CGFloat(day) - midDay
                let xr = u * cosA - v * sinA
                let yr = u * sinA + v * cosA
                return CGPoint(
                    x: centerX + xr * gridScale,
                    y: centerY + yr * gridScale * pitch
                )
            }

            func quadVertices(at center: CGPoint) -> [CGPoint] {
                let n = CGPoint(x: center.x - eW.x - eD.x, y: center.y - eW.y - eD.y)
                let e = CGPoint(x: center.x + eW.x - eD.x, y: center.y + eW.y - eD.y)
                let s = CGPoint(x: center.x + eW.x + eD.x, y: center.y + eW.y + eD.y)
                let w = CGPoint(x: center.x - eW.x + eD.x, y: center.y - eW.y + eD.y)
                return [n, e, s, w]
            }
        }

        func morphFrame(t: CGFloat, yaw: Double) -> MorphFrame {
            let angle = (.pi / 4.0) * Double(t) + yaw
            let cosA = CGFloat(cos(angle))
            let sinA = CGFloat(sin(angle))
            let pitch = 1.0 + (isoPitchRatio - 1.0) * t
            let isoGridScale = isoStepX * CGFloat(2.0).squareRoot()
            let gridScale = flatPitch + (isoGridScale - flatPitch) * t
            let flatMidX = flatOriginX + midWeek * flatPitch + flatCell * 0.5
            let flatMidY = flatOriginY + midDay * flatPitch + flatCell * 0.5
            let centerX = flatMidX + (isoCenterX - flatMidX) * t
            let centerY = flatMidY + (isoCenterY - flatMidY) * t
            let fillRatio = 0.80 + (0.78 - 0.80) * t
            let halfSide = gridScale * fillRatio * 0.5
            let eW = CGPoint(x: halfSide * cosA, y: halfSide * sinA * pitch)
            let eD = CGPoint(x: -halfSide * sinA, y: halfSide * cosA * pitch)
            let baseRadius = max(2.5, flatCell * 0.22)
            let cornerRadius = baseRadius * max(0, 1.0 - t * 2.2)
            return MorphFrame(
                cosA: cosA,
                sinA: sinA,
                gridScale: gridScale,
                pitch: pitch,
                centerX: centerX,
                centerY: centerY,
                eW: eW,
                eD: eD,
                cornerRadius: cornerRadius
            )
        }

        func flatCenter(week: Int, day: Int) -> CGPoint {
            CGPoint(
                x: flatOriginX + CGFloat(week) * flatPitch + flatCell / 2,
                y: flatOriginY + CGFloat(day) * flatPitch + flatCell / 2
            )
        }

        func rotatedDepth(week: Int, day: Int) -> CGFloat {
            let u = CGFloat(week) - midWeek
            let v = CGFloat(day) - midDay
            let x0 = u - v
            let y0 = u + v
            return x0 * sinYaw + y0 * cosYaw
        }

        func isoCenter(week: Int, day: Int) -> CGPoint {
            let u = CGFloat(week) - midWeek
            let v = CGFloat(day) - midDay
            let x0 = u - v
            let y0 = u + v
            let xr = x0 * cosYaw - y0 * sinYaw
            let yr = x0 * sinYaw + y0 * cosYaw
            return CGPoint(
                x: isoCenterX + xr * isoStepX,
                y: isoCenterY + yr * isoStepX * isoPitchRatio
            )
        }

        func diamondVertices(at center: CGPoint) -> [CGPoint] {
            let n = CGPoint(x: center.x - eW.x - eD.x, y: center.y - eW.y - eD.y)
            let e = CGPoint(x: center.x + eW.x - eD.x, y: center.y + eW.y - eD.y)
            let s = CGPoint(x: center.x + eW.x + eD.x, y: center.y + eW.y + eD.y)
            let w = CGPoint(x: center.x - eW.x + eD.x, y: center.y - eW.y + eD.y)
            return [n, e, s, w]
        }

        func prismBoundingRect(center: CGPoint, height: CGFloat) -> CGRect {
            let v = diamondVertices(at: center)
            let minX = min(min(v[0].x, v[1].x), min(v[2].x, v[3].x))
            let maxX = max(max(v[0].x, v[1].x), max(v[2].x, v[3].x))
            let minY = min(min(v[0].y, v[1].y), min(v[2].y, v[3].y)) - height
            let maxY = max(max(v[0].y, v[1].y), max(v[2].y, v[3].y))
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        func tierHeight(_ tier: Int) -> CGFloat {
            switch tier {
            case 0: max(1.5, maxTowerHeight * (3.0 / 96.0))
            case 1: maxTowerHeight * (19.0 / 96.0)
            case 2: maxTowerHeight * (38.0 / 96.0)
            case 3: maxTowerHeight * (64.0 / 96.0)
            default: maxTowerHeight
            }
        }
    }
}

// MARK: - Native Camera HUD Button

private struct CameraHUDButton<Label: View>: View {
    let isEnabled: Bool
    let helpText: String
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isEnabled ? Color.primary.opacity(isHovered ? 1.0 : 0.86) : Color.secondary.opacity(0.4))
                .background(
                    isHovered && isEnabled ? Color.primary.opacity(0.11) : Color.clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - AppKit Trackpad 2-Finger Orbit, Pinch Zoom & Mouse-Drag Event Catcher

private struct HeatmapOrbitEventCatcher: NSViewRepresentable {
    let allowVerticalTwoFingerOrbit: Bool
    let is3DActive: Bool
    let onHoverMove: (CGPoint) -> Void
    let onHoverExit: (Bool) -> Void
    let onClick: (CGPoint) -> Void
    let onDoubleClick: () -> Bool
    let onOrbitDelta: (CGFloat, CGFloat) -> Void
    let onPanDelta: (CGFloat, CGFloat) -> Bool
    let onZoomFactor: (Double, CGPoint) -> Void
    let onSmartMagnify: (CGPoint) -> Void
    let onOrbitEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onHoverMove: onHoverMove,
            onHoverExit: onHoverExit,
            onClick: onClick,
            onDoubleClick: onDoubleClick,
            onOrbitDelta: onOrbitDelta,
            onPanDelta: onPanDelta,
            onZoomFactor: onZoomFactor,
            onSmartMagnify: onSmartMagnify,
            onOrbitEnd: onOrbitEnd
        )
    }

    func makeNSView(context: Context) -> OrbitInteractionNSView {
        let view = OrbitInteractionNSView()
        view.coordinator = context.coordinator
        view.allowVerticalTwoFingerOrbit = allowVerticalTwoFingerOrbit
        view.is3DActive = is3DActive
        return view
    }

    func updateNSView(_ nsView: OrbitInteractionNSView, context: Context) {
        context.coordinator.onHoverMove = onHoverMove
        context.coordinator.onHoverExit = onHoverExit
        context.coordinator.onClick = onClick
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onOrbitDelta = onOrbitDelta
        context.coordinator.onPanDelta = onPanDelta
        context.coordinator.onZoomFactor = onZoomFactor
        context.coordinator.onSmartMagnify = onSmartMagnify
        context.coordinator.onOrbitEnd = onOrbitEnd
        nsView.allowVerticalTwoFingerOrbit = allowVerticalTwoFingerOrbit
        nsView.is3DActive = is3DActive
    }

    static func dismantleNSView(_ nsView: OrbitInteractionNSView, coordinator: Coordinator) {
        nsView.teardownMonitors()
    }

    @MainActor
    final class Coordinator {
        var onHoverMove: (CGPoint) -> Void
        var onHoverExit: (Bool) -> Void
        var onClick: (CGPoint) -> Void
        var onDoubleClick: () -> Bool
        var onOrbitDelta: (CGFloat, CGFloat) -> Void
        var onPanDelta: (CGFloat, CGFloat) -> Bool
        var onZoomFactor: (Double, CGPoint) -> Void
        var onSmartMagnify: (CGPoint) -> Void
        var onOrbitEnd: () -> Void

        init(
            onHoverMove: @escaping (CGPoint) -> Void,
            onHoverExit: @escaping (Bool) -> Void,
            onClick: @escaping (CGPoint) -> Void,
            onDoubleClick: @escaping () -> Bool,
            onOrbitDelta: @escaping (CGFloat, CGFloat) -> Void,
            onPanDelta: @escaping (CGFloat, CGFloat) -> Bool,
            onZoomFactor: @escaping (Double, CGPoint) -> Void,
            onSmartMagnify: @escaping (CGPoint) -> Void,
            onOrbitEnd: @escaping () -> Void
        ) {
            self.onHoverMove = onHoverMove
            self.onHoverExit = onHoverExit
            self.onClick = onClick
            self.onDoubleClick = onDoubleClick
            self.onOrbitDelta = onOrbitDelta
            self.onPanDelta = onPanDelta
            self.onZoomFactor = onZoomFactor
            self.onSmartMagnify = onSmartMagnify
            self.onOrbitEnd = onOrbitEnd
        }
    }
}

private final class OrbitInteractionNSView: NSView {
    weak var coordinator: HeatmapOrbitEventCatcher.Coordinator?
    var allowVerticalTwoFingerOrbit: Bool = true
    var is3DActive: Bool = true

    private var trackingArea: NSTrackingArea?
    private nonisolated(unsafe) var localGestureMonitor: Any?
    private var lastHandledMagnifyTimestamp: TimeInterval = -1
    private var isTwoFingerOrbiting = false
    private var wheelReleaseTask: Task<Void, Never>?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    deinit {
        if let monitor = localGestureMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func teardownMonitors() {
        wheelReleaseTask?.cancel()
        wheelReleaseTask = nil
        if let monitor = localGestureMonitor {
            NSEvent.removeMonitor(monitor)
            localGestureMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardownMonitors()
        } else {
            installLocalGestureMonitorIfNeeded()
            updateTrackingAreas()
        }
    }

    /// Intercepts trackpad pinch (`.magnify`) and 2-finger double-tap (`.smartMagnify`) at the
    /// `NSApplication` level BEFORE `NSHostingView`, `NSScrollView`, or `NSGlassEffectView` can swallow them.
    private func installLocalGestureMonitorIfNeeded() {
        guard localGestureMonitor == nil else { return }
        localGestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak self] event in
            guard let self else { return event }
            return self.interceptGestureEvent(event)
        }
    }

    private func interceptGestureEvent(_ event: NSEvent) -> NSEvent? {
        guard is3DActive,
              let win = window,
              win.isVisible,
              !isHiddenOrHasHiddenAncestor else {
            return event
        }

        // Route strictly to the topmost visible window under the cursor (works for both Dashboard and Desktop Widget)
        let screenPt = NSEvent.mouseLocation
        let topWinNum = NSWindow.windowNumber(at: screenPt, belowWindowWithWindowNumber: 0)
        if topWinNum != win.windowNumber {
            guard event.window === win, NSApp.window(withWindowNumber: topWinNum) == nil else {
                return event
            }
        }

        let winPt = win.convertPoint(fromScreen: screenPt)
        let localPt = convert(winPt, from: nil)
        guard bounds.contains(localPt) else { return event }

        if event.type == .magnify {
            handleMagnify(event, at: localPt)
            return nil
        }
        if event.type == .smartMagnify {
            handleSmartMagnify(event, at: localPt)
            return nil
        }
        return event
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect]
        if window is NSPanel {
            options.insert(.activeAlways)
        } else {
            options.insert(.activeInKeyWindow)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let win = window else { return }
        if win is NSPanel {
            let topWinNum = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            guard topWinNum == win.windowNumber else {
                coordinator?.onHoverExit(true)
                return
            }
        }
        guard win.contentView?.hitTest(event.locationInWindow) === self else {
            coordinator?.onHoverExit(false)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        coordinator?.onHoverMove(pt)
    }

    override func mouseExited(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let leftBounds = !bounds.contains(pt)
        coordinator?.onHoverExit(leftBounds)
    }

    // MARK: - Trackpad Pinch-to-Zoom & 2-Finger Smart Magnify

    override func magnify(with event: NSEvent) {
        guard is3DActive else {
            super.magnify(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        handleMagnify(event, at: pt)
    }

    private func handleMagnify(_ event: NSEvent, at pt: CGPoint) {
        if event.timestamp == lastHandledMagnifyTimestamp { return }
        lastHandledMagnifyTimestamp = event.timestamp

        let phase = event.phase
        if phase == .ended || phase == .cancelled {
            wheelReleaseTask?.cancel()
            coordinator?.onOrbitEnd()
            return
        }

        let delta = Double(event.magnification)
        if abs(delta) > 0.0001 {
            // Exponential magnification is perfectly symmetric (pinch out +d then in -d returns to exact 1.0x)
            let factor = max(0.5, min(2.0, exp(delta * 1.45)))
            wheelReleaseTask?.cancel()
            coordinator?.onZoomFactor(factor, pt)
        }

        if phase == [] {
            scheduleWheelSettle()
        }
    }

    override func smartMagnify(with event: NSEvent) {
        guard is3DActive else {
            super.smartMagnify(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        handleSmartMagnify(event, at: pt)
    }

    private func handleSmartMagnify(_ event: NSEvent, at pt: CGPoint) {
        if event.timestamp == lastHandledMagnifyTimestamp { return }
        lastHandledMagnifyTimestamp = event.timestamp
        coordinator?.onSmartMagnify(pt)
    }

    // MARK: - Mouse Wheel Direct Zoom, ⌘/⌥ + Trackpad Zoom, and 2-Finger Trackpad Sticky Orbit

    override func scrollWheel(with event: NSEvent) {
        guard is3DActive else {
            super.scrollWheel(with: event)
            return
        }

        let isZoomModifier = !event.modifierFlags.intersection([.command, .option]).isEmpty
        // Physical mouse wheels (stepped OR smooth-scroll drivers like Logi Options+ / Mos) have no touch phase;
        // rolling the mouse wheel over the 3D heatmap zooms directly (no modifier key needed!), while drag orbits.
        let isMouseWheel = !event.hasPreciseScrollingDeltas || (event.phase == [] && event.momentumPhase == [])

        if isZoomModifier || isMouseWheel {
            if event.momentumPhase != [] { return }
            let phase = event.phase
            if phase == .ended || phase == .cancelled {
                wheelReleaseTask?.cancel()
                coordinator?.onOrbitEnd()
                return
            }
            let rawY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : (event.scrollingDeltaY * 14.0)
            // Physical scroll UP (wheel forward / fingers pushed up) always zooms IN
            let physicalUp = event.isDirectionInvertedFromDevice ? -rawY : rawY
            if abs(physicalUp) > 0.01 {
                let pt = convert(event.locationInWindow, from: nil)
                let factor = max(0.5, min(2.0, exp(Double(physicalUp) * 0.0085)))
                wheelReleaseTask?.cancel()
                coordinator?.onZoomFactor(factor, pt)
                if phase == [] {
                    scheduleWheelSettle()
                }
            }
            return
        }

        if event.momentumPhase != [] {
            return
        }

        let phase = event.phase
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : (event.scrollingDeltaX * 8.0)
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : (event.scrollingDeltaY * 8.0)

        if !allowVerticalTwoFingerOrbit && !isTwoFingerOrbiting {
            if abs(dx) < abs(dy) * 0.75 {
                super.scrollWheel(with: event)
                return
            }
        }

        if phase == .ended || phase == .cancelled {
            isTwoFingerOrbiting = false
            wheelReleaseTask?.cancel()
            coordinator?.onOrbitEnd()
            return
        }

        if phase == .began || phase == .changed {
            isTwoFingerOrbiting = true
            wheelReleaseTask?.cancel()
            coordinator?.onOrbitDelta(dx, dy)
            return
        }

        if abs(dx) > 0.01 || abs(dy) > 0.01 {
            coordinator?.onOrbitDelta(dx, dy)
            scheduleWheelSettle()
        }
    }

    private func scheduleWheelSettle() {
        wheelReleaseTask?.cancel()
        wheelReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.coordinator?.onOrbitEnd()
        }
    }

    // MARK: - Mouse Click / Double-Click Reset / Sticky Drag-to-Orbit (or Shift-Drag Pan when Zoomed)

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        // Double-click resets a rotated or zoomed 3D map cleanly back to default angle & 100%
        if event.clickCount == 2, coordinator?.onDoubleClick() == true {
            return
        }

        let startPt = convert(event.locationInWindow, from: nil)
        var lastPt = startPt
        var dragged = false
        var endedOrbit = false
        var didPushClosedHand = false
        defer {
            if didPushClosedHand {
                NSCursor.pop()
            }
            if dragged && !endedOrbit {
                coordinator?.onOrbitEnd()
            }
        }

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .greatestFiniteMagnitude,
            mode: .eventTracking
        ) { [weak self] nextEvent, stop in
            guard let self, let nextEvent else { return }
            let pt = self.convert(nextEvent.locationInWindow, from: nil)

            if nextEvent.type == .leftMouseUp {
                stop.pointee = true
                if dragged {
                    endedOrbit = true
                    self.coordinator?.onOrbitEnd()
                } else {
                    self.coordinator?.onClick(pt)
                }
                return
            }

            guard self.is3DActive else { return }
            if !dragged {
                if hypot(pt.x - startPt.x, pt.y - startPt.y) >= 4.0 {
                    dragged = true
                    NSCursor.closedHand.push()
                    didPushClosedHand = true
                } else {
                    return
                }
            }
            let dx = pt.x - lastPt.x
            let dy = pt.y - lastPt.y
            lastPt = pt

            let wantsPan = !nextEvent.modifierFlags.intersection([.shift, .option]).isEmpty
            if wantsPan, self.coordinator?.onPanDelta(dx, dy) == true {
                return
            }
            // Direct-manipulation 3D grab-and-drag: dragging right rotates the front of the model right (-dx),
            // and dragging down tilts the skyline downward toward top-down (+dy), independent of 2-finger trackpad scroll.
            self.coordinator?.onOrbitDelta(-dx * 1.15, dy * 1.15)
        }
    }
}
