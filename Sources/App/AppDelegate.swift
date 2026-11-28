import AppKit
import Carbon.HIToolbox
import os
import SwiftUI

/// Coordinates desktop panel lifecycle, smart Dock activation policy (`.accessory` ↔ `.regular`),
/// single Dashboard/Settings windows, and Carbon global hotkey `⌃⌥T` (zero Accessibility permissions needed).
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = Logger(subsystem: "io.github.stankela16.milkit", category: "AppDelegate")

    public let state = AppState()
    private var panelController: DesktopPanelController?
    private var statusItem: NSStatusItem?
    private var floatMenuItem: NSMenuItem?
    private var demoMenuItem: NSMenuItem?
    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid spawning live UI panel or FSEvents ingestion when hosted by XCTest
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        // Start hidden from Dock while only the desktop widget is displayed (D6),
        // except in --demo showcase mode where showing Milkit in the Dock & top-left menu bar is helpful.
        let isDemoLaunch = ProcessInfo.processInfo.arguments.contains("--demo")
        NSApp.setActivationPolicy(isDemoLaunch ? .regular : .accessory)

        let controller = DesktopPanelController(state: state)
        self.panelController = controller

        state.onFloatOnTopChanged = { [weak controller] floatOnTop in
            controller?.applyWindowLevel(floatOnTop: floatOnTop)
        }
        state.onLockPositionChanged = { [weak controller] locked in
            controller?.applyLockPosition(locked)
        }
        state.onApplyWidgetSizePreset = { [weak controller] preset in
            controller?.applySizePreset(preset)
        }
        state.onAppearanceChanged = { [weak controller] mode in
            controller?.applyAppearance(mode)
            Self.applyAppWindowAppearance(mode)
        }
        state.onOpenDashboard = { [weak self] in
            self?.summonDashboard()
        }
        state.onOpenSettings = { [weak self] in
            self?.summonSettings()
        }

        controller.show()
        setupMenuBarItem()
        if !state.isDemoMode {
            state.startEngineIfNeeded()
        }
        registerGlobalHotKey()
        observeNormalWindowLifecycle()
    }

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let img = NSImage(named: "MenuBarIcon") {
                img.isTemplate = true
                img.size = NSSize(width: 16, height: 16)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Milkit")
            }
            button.toolTip = "Milkit"
        }

        let menu = NSMenu()
        menu.delegate = self
        let openDash = NSMenuItem(title: "Open Analytics Dashboard", action: #selector(menuOpenDashboard), keyEquivalent: "t")
        openDash.keyEquivalentModifierMask = [.control, .option]
        openDash.target = self
        menu.addItem(openDash)

        let toggle3D = NSMenuItem(title: "Toggle Widget 2D / 3D", action: #selector(menuToggleWidget3D), keyEquivalent: "")
        toggle3D.target = self
        menu.addItem(toggle3D)

        let floatItem = NSMenuItem(title: "Float Widget on Top", action: #selector(menuToggleFloatOnTop), keyEquivalent: "")
        floatItem.target = self
        floatItem.state = state.floatOnTop ? .on : .off
        menu.addItem(floatItem)
        self.floatMenuItem = floatItem

        let demoItem = NSMenuItem(title: "Toggle Demo Mode", action: #selector(menuToggleDemoMode), keyEquivalent: "")
        demoItem.target = self
        demoItem.state = state.isDemoMode ? .on : .off
        menu.addItem(demoItem)
        self.demoMenuItem = demoItem

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Milkit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        floatMenuItem?.state = state.floatOnTop ? .on : .off
        demoMenuItem?.state = state.isDemoMode ? .on : .off
    }

    @objc private func menuOpenDashboard() {
        summonDashboard()
    }

    @objc private func menuToggleWidget3D() {
        state.widgetIs3D.toggle()
    }

    @objc private func menuToggleFloatOnTop() {
        state.floatOnTop.toggle()
    }

    @objc private func menuToggleDemoMode() {
        state.isDemoMode.toggle()
    }

    @objc private func menuOpenSettings() {
        summonSettings()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasOpenStandardWindow = [dashboardWindow, settingsWindow]
            .compactMap { $0 }
            .contains { $0.isVisible && !$0.isMiniaturized }
        if !hasOpenStandardWindow {
            summonDashboard()
        }
        return true
    }

    public func summonDashboard() {
        NSApp.setActivationPolicy(.regular)
        if let existing = dashboardWindow {
            Self.applyWindowAppearance(state.appearanceOverride, to: existing)
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: DashboardView(state: state))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Milkit"
            win.titleVisibility = .hidden
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.toolbarStyle = .unified
            win.setContentSize(NSSize(width: 1120, height: 760))
            win.minSize = NSSize(width: 900, height: 620)
            win.isReleasedWhenClosed = false
            win.center()
            win.setFrameUsingName("MilkitDashboardWindow")
            win.setFrameAutosaveName("MilkitDashboardWindow")
            Self.applyWindowAppearance(state.appearanceOverride, to: win)
            self.dashboardWindow = win
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    public func summonSettings() {
        NSApp.setActivationPolicy(.regular)
        if let existing = settingsWindow {
            Self.applyWindowAppearance(state.appearanceOverride, to: existing)
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Milkit Settings"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 480, height: 660))
            win.isReleasedWhenClosed = false
            win.center()
            win.setFrameUsingName("MilkitSettingsWindowV3")
            win.setFrameAutosaveName("MilkitSettingsWindowV3")
            Self.applyWindowAppearance(state.appearanceOverride, to: win)
            self.settingsWindow = win
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    private func observeNormalWindowLifecycle() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let closingWindow = notification.object as? NSWindow
            Task { @MainActor [weak self] in
                self?.updateDockPolicyIfNeeded(excluding: closingWindow)
            }
        }
    }

    private func updateDockPolicyIfNeeded(excluding closingWindow: NSWindow? = nil) {
        let managed = [dashboardWindow, settingsWindow].compactMap { $0 }
        let hasActiveStandardWindow = managed.contains { w in
            w !== closingWindow && (w.isVisible || w.isMiniaturized)
        }
        if !hasActiveStandardWindow && NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func applyAppWindowAppearance(_ mode: AppearanceOverride) {
        for w in NSApp.windows where !(w is NSPanel) {
            applyWindowAppearance(mode, to: w)
        }
    }

    private static func applyWindowAppearance(_ mode: AppearanceOverride, to window: NSWindow) {
        switch mode {
        case .system: window.appearance = nil
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        case .light: window.appearance = NSAppearance(named: .aqua)
        }
    }

    // MARK: - Carbon Global HotKey (⌃⌥T)

    private func registerGlobalHotKey() {
        guard hotKeyRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == 0x4D4C4B54, hotKeyID.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                delegate.summonDashboard()
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )
        if installStatus != noErr {
            logger.warning("InstallEventHandler failed with OSStatus \(installStatus)")
        }

        let hotKeyID = EventHotKeyID(signature: 0x4D4C4B54, id: 1) // 'MLKT'
        // kVK_ANSI_T = 17, modifiers = controlKey + optionKey (⌃⌥T — zero collision with browser ⌘⇧T)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            logger.warning("RegisterEventHotKey (⌃⌥T) failed with OSStatus \(registerStatus)")
        }
    }
}
