import AppKit
import SwiftUI

/// Borderless desktop panel that accepts click-to-focus so native trackpad pinch-to-zoom (`magnify`)
/// and keyboard shortcuts route cleanly while the app stays in `.accessory` policy (zero Dock icon,
/// zero menu bar switch).
private final class DesktopWidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts first-mouse clicks immediately when the desktop panel is inactive.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Manages the borderless, resizable, desktop-pinned native macOS `NSPanel` wrapped in a single
/// `NSGlassEffectView` on macOS 26+ (or frosted `NSVisualEffectView` fallback on macOS 15 Sequoia),
/// persisting `(x, y, width, height)` cleanly and honoring `Reduce Transparency` + `Lock Position`.
@MainActor
public final class DesktopPanelController: NSObject, NSWindowDelegate {
    public static let minWidgetSize = NSSize(width: 340, height: 220)
    public static let maxWidgetSize = NSSize(width: 720, height: 460)
    public static let defaultWidgetSize = NSSize(width: 424, height: 260)

    private let panel: NSPanel
    private let glassView: NSView?
    private let hostingView: OverlayHostingView<DesktopWidgetView>
    private let state: AppState
    private var isUsingSolidFallback = false
    private var saveFrameTask: Task<Void, Never>?

    private enum DefaultsKey {
        static let originX = "milkit.panel.originX"
        static let originY = "milkit.panel.originY"
        static let width = "milkit.panel.width"
        static let height = "milkit.panel.height"
    }

    public init(state: AppState) {
        self.state = state

        let initialFrame = Self.restoredFrame()

        let p = DesktopWidgetPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        p.minSize = Self.minWidgetSize
        p.maxSize = Self.maxWidgetSize
        p.becomesKeyOnlyIfNeeded = false
        p.isMovableByWindowBackground = !state.widgetLockPosition
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        // NSGlassEffectView renders its own native rounded glass shadow; window-level shadow creates
        // rectangular corner artifacts outside the 26pt radius on resizable borderless panels.
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let glass: NSView?
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Single outer NSGlassEffectView — never mutate `.wantsLayer` or `.layer` on NSGlassEffectView!
            let g = NSGlassEffectView(frame: NSRect(origin: .zero, size: initialFrame.size))
            g.style = .regular
            g.cornerRadius = 26
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                g.effectIsInteractive = true
            }
            #endif
            g.autoresizingMask = [.width, .height]
            glass = g
        } else {
            glass = Self.makeVisualEffectFallback(size: initialFrame.size)
        }
        #else
        glass = Self.makeVisualEffectFallback(size: initialFrame.size)
        #endif

        let hosting = OverlayHostingView(rootView: DesktopWidgetView(state: state))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: initialFrame.size)
        hosting.autoresizingMask = [.width, .height]

        self.panel = p
        self.glassView = glass
        self.hostingView = hosting
        super.init()

        // Mount initial surface once (solid fallback only if Reduce Transparency is enabled)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            self.isUsingSolidFallback = true
            mountSolidContainer()
        } else {
            self.isUsingSolidFallback = false
            mountGlassContainer()
        }

        p.delegate = self
        applyWindowLevel(floatOnTop: state.floatOnTop)
        applyAppearance(state.appearanceOverride)
        applyLockPosition(state.widgetLockPosition)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncTransparencyPreferenceIfNeeded()
            }
        }
    }

    public func show() {
        panel.orderFrontRegardless()
    }

    public func applyWindowLevel(floatOnTop: Bool) {
        if floatOnTop {
            panel.level = .floating
        } else {
            // Exact Apple Desktop Widget plane verified on macOS 27.2.1 (`desktopIconWindow + 2`)
            let desktopWidgetLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 2
            panel.level = NSWindow.Level(rawValue: desktopWidgetLevel)
        }
    }

    public func applyLockPosition(_ locked: Bool) {
        panel.isMovableByWindowBackground = !locked
        if locked {
            panel.styleMask.remove(.resizable)
        } else {
            panel.styleMask.insert(.resizable)
        }
        panel.minSize = Self.minWidgetSize
        panel.maxSize = Self.maxWidgetSize
    }

    /// Resizes smoothly while keeping the widget's top-right anchor stable on the desktop.
    public func applySizePreset(_ preset: WidgetSizePreset) {
        let targetSize = preset.dimensions
        let current = panel.frame
        let newX = current.maxX - targetSize.width
        let newY = current.maxY - targetSize.height
        var target = NSRect(x: newX, y: newY, width: targetSize.width, height: targetSize.height)

        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            target.origin.x = min(max(target.origin.x, visible.minX + 12), visible.maxX - target.width - 12)
            target.origin.y = min(max(target.origin.y, visible.minY + 12), visible.maxY - target.height - 12)
        }

        panel.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        scheduleFrameSave()
    }

    public func applyAppearance(_ override: AppearanceOverride) {
        switch override {
        case .system:
            panel.appearance = nil
        case .dark:
            panel.appearance = NSAppearance(named: .darkAqua)
        case .light:
            panel.appearance = NSAppearance(named: .aqua)
        }
        if isUsingSolidFallback {
            mountSolidContainer()
        }
    }

    private func syncTransparencyPreferenceIfNeeded() {
        let shouldUseSolid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard shouldUseSolid != isUsingSolidFallback else { return }
        isUsingSolidFallback = shouldUseSolid
        if shouldUseSolid {
            mountSolidContainer()
        } else {
            mountGlassContainer()
        }
    }

    /// Wraps `NSGlassEffectView` (macOS 26+) or `NSVisualEffectView` (macOS 15) in a continuous 26pt masked
    /// container (without mutating `NSGlassEffectView.layer`) so active key-window glass shadow never bleeds
    /// dark triangles into the 4 square window corners.
    private func mountGlassContainer() {
        let clipContainer = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        clipContainer.wantsLayer = true
        clipContainer.layer?.cornerRadius = 26
        clipContainer.layer?.cornerCurve = .continuous
        clipContainer.layer?.masksToBounds = true
        clipContainer.autoresizingMask = [.width, .height]

        hostingView.removeFromSuperview()
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
            g.removeFromSuperview()
            g.frame = clipContainer.bounds
            hostingView.frame = g.bounds
            g.contentView = hostingView
            clipContainer.addSubview(g)
        } else if let vfx = glassView as? NSVisualEffectView {
            vfx.removeFromSuperview()
            vfx.frame = clipContainer.bounds
            hostingView.frame = vfx.bounds
            vfx.addSubview(hostingView)
            clipContainer.addSubview(vfx)
        } else {
            hostingView.frame = clipContainer.bounds
            clipContainer.addSubview(hostingView)
        }
        #else
        if let vfx = glassView as? NSVisualEffectView {
            vfx.removeFromSuperview()
            vfx.frame = clipContainer.bounds
            hostingView.frame = vfx.bounds
            vfx.addSubview(hostingView)
            clipContainer.addSubview(vfx)
        } else {
            hostingView.frame = clipContainer.bounds
            clipContainer.addSubview(hostingView)
        }
        #endif
        panel.contentView = clipContainer
    }

    private static func makeVisualEffectFallback(size: NSSize) -> NSVisualEffectView {
        let vfx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        vfx.material = .hudWindow
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.autoresizingMask = [.width, .height]
        return vfx
    }

    private func mountSolidContainer() {
        let solidContainer = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        solidContainer.wantsLayer = true
        solidContainer.layer?.cornerRadius = 26
        solidContainer.layer?.cornerCurve = .continuous
        solidContainer.layer?.masksToBounds = true
        solidContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        solidContainer.layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.5 : 1.0
        solidContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        solidContainer.autoresizingMask = [.width, .height]

        hostingView.removeFromSuperview()
        hostingView.frame = solidContainer.bounds
        solidContainer.addSubview(hostingView)
        panel.contentView = solidContainer
    }

    public func windowDidMove(_ notification: Notification) {
        scheduleFrameSave()
    }

    public func windowDidResize(_ notification: Notification) {
        scheduleFrameSave()
    }

    private func scheduleFrameSave() {
        let frame = panel.frame
        saveFrameTask?.cancel()
        saveFrameTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let ud = UserDefaults.standard
            ud.set(frame.origin.x, forKey: DefaultsKey.originX)
            ud.set(frame.origin.y, forKey: DefaultsKey.originY)
            ud.set(frame.size.width, forKey: DefaultsKey.width)
            ud.set(frame.size.height, forKey: DefaultsKey.height)
        }
    }

    private static func restoredFrame() -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 920)
        let ud = UserDefaults.standard

        let savedW = ud.double(forKey: DefaultsKey.width)
        let savedH = ud.double(forKey: DefaultsKey.height)
        let width = (savedW >= minWidgetSize.width && savedW <= maxWidgetSize.width) ? savedW : defaultWidgetSize.width
        let height = (savedH >= minWidgetSize.height && savedH <= maxWidgetSize.height) ? savedH : defaultWidgetSize.height
        let size = NSSize(width: width, height: height)

        if ud.object(forKey: DefaultsKey.originX) != nil && ud.object(forKey: DefaultsKey.originY) != nil {
            let x = ud.double(forKey: DefaultsKey.originX)
            let y = ud.double(forKey: DefaultsKey.originY)
            let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                return candidate
            }
        }
        // Default: top-right corner of desktop with crisp 24pt HIG margin
        let x = screenFrame.maxX - size.width - 24
        let y = screenFrame.maxY - size.height - 24
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
