import SwiftUI

@main
struct MilkitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Commands live on a lightweight hidden Settings placeholder; `.appSettings` is replaced so
        // every shortcut (`⌘,`), menu item, and toolbar icon routes to the single AppDelegate settings window.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.summonSettings()
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Open Analytics Dashboard") {
                    appDelegate.summonDashboard()
                }
                .keyboardShortcut("t", modifiers: [.control, .option])
            }

            CommandMenu("Telemetry") {
                Button("Refresh Local Sources") {
                    appDelegate.state.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                ForEach(Array(DashboardTab.allCases.enumerated()), id: \.element.id) { index, tab in
                    Button {
                        appDelegate.state.selectedTab = tab
                        appDelegate.summonDashboard()
                    } label: {
                        if appDelegate.state.selectedTab == tab {
                            Label(tab.rawValue, systemImage: "checkmark")
                        } else {
                            Text(tab.rawValue)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }

                Divider()

                Button(appDelegate.state.dashboardIs3D ? "Switch Dashboard to 2D" : "Switch Dashboard to 3D") {
                    appDelegate.state.dashboardIs3D.toggle()
                }
                .keyboardShortcut("d", modifiers: .command)

                Button(appDelegate.state.widgetIs3D ? "Switch Desktop Widget to 2D" : "Switch Desktop Widget to 3D") {
                    appDelegate.state.widgetIs3D.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Divider()

                Menu("Heatmap Metric") {
                    ForEach(HeatmapMetric.allCases) { metric in
                        Button {
                            appDelegate.state.heatmapMetric = metric
                        } label: {
                            if appDelegate.state.heatmapMetric == metric {
                                Label(metric.rawValue, systemImage: "checkmark")
                            } else {
                                Text(metric.rawValue)
                            }
                        }
                    }
                }
            }
        }
    }
}
