import SwiftUI

public struct SettingsView: View {
    @Bindable var state: AppState
    @State private var showRebuildConfirm = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Form {
            Section("Appearance & Widget") {
                Picker("Theme", selection: $state.appearanceOverride) {
                    ForEach(AppearanceOverride.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Override system Light or Dark appearance across Widget and Dashboard")

                Picker("Default Metric", selection: $state.heatmapMetric) {
                    ForEach(HeatmapMetric.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose the primary metric displayed on the Desktop Widget and 3D Heatmap")

                Picker("Widget Heatmap Span", selection: $state.widgetWeeks) {
                    Text("8 weeks").tag(8)
                    Text("10 weeks").tag(10)
                    Text("12 weeks").tag(12)
                    Text("14 weeks").tag(14)
                    Text("16 weeks").tag(16)
                }
                .help("Number of weeks rendered on the Desktop Widget (8–10w fills the skyline tightly)")

                LabeledContent("Widget Size") {
                    HStack(spacing: 8) {
                        ForEach(WidgetSizePreset.allCases) { preset in
                            Button(preset.rawValue) {
                                SoundEngine.shared.play(.click)
                                state.onApplyWidgetSizePreset?(preset)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(state.widgetLockPosition)
                            .help("Resize widget to \(Int(preset.dimensions.width))×\(Int(preset.dimensions.height)) pt (or drag bottom-right corner freely)")
                        }
                    }
                }

                Toggle("Float Widget on Top of Windows", isOn: $state.floatOnTop)
                    .help("Keep the Desktop Widget floating above application windows")

                Toggle("Lock Widget Position & Size", isOn: $state.widgetLockPosition)
                    .help("Prevent accidental moving or resizing of the Desktop Widget")
            }

            Section("Sound Effects") {
                Toggle("Play Tactile UI Sounds", isOn: $state.soundEffectsEnabled)
                    .help("Play subtle glass/marimba sounds on click, hover, 2D/3D morph, and live token arrivals")

                HStack(spacing: 12) {
                    Text("Volume")
                    Slider(value: $state.soundVolume, in: 0.05...1.0)
                        .disabled(!state.soundEffectsEnabled)
                        .help("Adjust UI sound effect volume")
                    Button("Test") {
                        SoundEngine.shared.play(.morph3D, force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Preview the 3D morph chime")
                }
            }

            Section("Shortcuts & Data") {
                LabeledContent("Open Dashboard", value: "⌃⌥T (Global)")
                LabeledContent("Tabs · 2D/3D · Refresh", value: "⌘1–3 · ⌘D · ⌘R")

                Toggle("Demo Mode (Sample Data)", isOn: $state.isDemoMode)
                    .help("Show anonymized sample activity across Claude Code, Codex CLI, and Antigravity (safe for screenshots & videos)")

                HStack(spacing: 12) {
                    Button("Refresh Local Sources") {
                        SoundEngine.shared.play(.click)
                        state.refreshNow()
                    }
                    .help("Scan for newly written Claude Code, Codex CLI, and Antigravity log deltas")

                    Spacer()

                    Button("Rebuild SQLite Index", role: .destructive) {
                        showRebuildConfirm = true
                    }
                    .help("Clear local rollup cache and re-index all session logs from scratch")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 660)
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
}
