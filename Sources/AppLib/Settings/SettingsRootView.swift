import AppKit
import Shared
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case notifications = "Notifications"
    case integrations = "Integrations"
    case about = "About"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .appearance: return "paintpalette"
        case .notifications: return "bell"
        case .integrations: return "point.3.connected.trianglepath.dotted"
        case .about: return "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var downloader: UpdateDownloader

    let changeHotkey: () -> Void
    let exportDiagnostics: () -> Void
    let uninstallIntegrations: () -> Void
    let quitApplication: () -> Void

    @State private var selection: SettingsSection = .general

    private let accent = AppColors.activity.color
    private let cardBackground = Color(white: 0.12)
    private let surfaceBackground = Color.white.opacity(0.035)
    private let transparentBorder = Color.white.opacity(0.12)
    private let secondaryForeground = Color.white.opacity(0.60)
    private static let websiteURL = URL(string: "https://zackeyes.vercel.app/")!

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(transparentBorder)
                .frame(width: 1)
            detail
        }
        .frame(minWidth: 660, minHeight: 460)
        .tint(accent)
        .foregroundStyle(Color.white)
        .background(cardBackground)
        .overlay(Rectangle().stroke(transparentBorder, lineWidth: 1))
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                appIcon
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ZackEyes")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryForeground)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                    if section == .integrations {
                        viewModel.refreshHookHealth()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: section.symbol)
                            .frame(width: 18)
                        Text(section.rawValue)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: selection == section ? .semibold : .regular))
                    .foregroundStyle(selection == section ? Color.white : secondaryForeground)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == section ? accent.opacity(0.15) : .clear)
                    )
                    .overlay {
                        if selection == section {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(accent.opacity(0.35), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: quitApplication) {
                Label("Quit ZackEyes", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.critical.color)
            .help("Quit ZackEyes")
        }
        .padding(12)
        .frame(width: 176)
        .background(surfaceBackground)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(selection.rawValue)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)

                switch selection {
                case .general: generalSettings
                case .appearance: appearanceSettings
                case .notifications: notificationSettings
                case .integrations: integrationSettings
                case .about: aboutSettings
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("Dynamic Island") {
                settingRow("Visibility") {
                    Picker("", selection: binding(viewModel.visibility, viewModel.setVisibility)) {
                        Text("Always").tag(NotchVisibility.always)
                        Text("When Active").tag(NotchVisibility.whenActive)
                        Text("Hidden").tag(NotchVisibility.hidden)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }

                settingRow("Preferred quota source") {
                    Picker("", selection: binding(viewModel.compactAgent, viewModel.setCompactAgent)) {
                        Text("Claude").tag(AgentKind.claude)
                        Text("Codex").tag(AgentKind.codex)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                settingRow("Progress mode") {
                    Picker("", selection: binding(viewModel.progressMode, viewModel.setProgressMode)) {
                        ForEach(ProgressMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                if viewModel.progressMode == .left {
                    settingRow("Fill direction") {
                        Picker("", selection: binding(
                            viewModel.leftProgressDirection,
                            viewModel.setLeftProgressDirection
                        )) {
                            Image(systemName: "arrow.right")
                                .accessibilityLabel("Left to right")
                                .help("Fill from left to right")
                                .tag(LeftProgressDirection.leftToRight)
                            Image(systemName: "arrow.left")
                                .accessibilityLabel("Right to left")
                                .help("Fill from right to left")
                                .tag(LeftProgressDirection.rightToLeft)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                }

                settingRow("Window elapsed") {
                    Picker("", selection: binding(
                        viewModel.timeProgressMode,
                        viewModel.setTimeProgressMode
                    )) {
                        ForEach(TimeProgressMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }

                if viewModel.timeProgressMode == .overlap {
                    settingRow("Overlay transparency") {
                        HStack(spacing: 8) {
                            Slider(
                                value: overlayTransparency,
                                in: 0...1,
                                step: 0.1
                            )
                            .frame(width: 220)
                            Text("\(Int((overlayTransparency.wrappedValue * 100).rounded()))%")
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 36, alignment: .trailing)
                        }
                        .frame(width: 280, alignment: .leading)
                    }
                }

                settingRow("Today's consumption") {
                    Toggle("", isOn: binding(
                        viewModel.showTodayConsumption,
                        viewModel.setShowTodayConsumption
                    ))
                    .labelsHidden()
                }
            }

            settingsGroup("Keyboard") {
                settingRow("Global shortcut") {
                    HStack(spacing: 10) {
                        Text(viewModel.hotkey.displayString)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(surfaceBackground, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(transparentBorder, lineWidth: 1)
                            )
                        Button("Change...", action: changeHotkey)
                    }
                }
            }

            if !viewModel.hasPhysicalNotch {
                settingsGroup("Position") {
                    settingRow("Simulated notch") {
                        HStack(spacing: 8) {
                            Button("Reposition...") {
                                viewModel.beginNotchRepositioning()
                            }
                            Button {
                                viewModel.resetNotchPosition()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .help("Reset to center")
                            .disabled(viewModel.notchOffsetX == 0)
                        }
                    }
                }
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("Buddy theme") {
                VStack(spacing: 0) {
                    ForEach(BuddyTheme.allCases, id: \.self) { theme in
                        Button {
                            viewModel.setTheme(theme)
                        } label: {
                            HStack(spacing: 12) {
                                themeIcon(theme)
                                Text(theme.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if viewModel.theme == theme {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(accent)
                                }
                            }
                            .frame(height: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if theme != BuddyTheme.allCases.last { Divider() }
                    }
                }
            }

            settingsGroup("Sound") {
                settingRow("Notification sound") {
                    HStack(spacing: 8) {
                        Picker("", selection: binding(
                            viewModel.notificationSound,
                            viewModel.setNotificationSound
                        )) {
                            ForEach(viewModel.theme.availableSounds, id: \.file) { sound in
                                Text(sound.name).tag(sound.file)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)

                        Button {
                            viewModel.previewNotificationSound()
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .help("Preview sound")
                        .disabled(viewModel.notificationSound == "none")
                    }
                }
            }
        }
    }

    private var notificationSettings: some View {
        settingsGroup("Attention") {
            settingRow("Agent needs input") {
                Toggle("", isOn: binding(
                    viewModel.notifyWaitingForInput,
                    viewModel.setNotifyWaitingForInput
                ))
                .labelsHidden()
            }
        }
    }

    private var integrationSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("Connection health") {
                healthRow("Claude hooks", status: agentStatus(viewModel.hookHealth.claudeHooks))
                healthRow("Codex hooks", status: agentStatus(viewModel.hookHealth.codexHooks))
                healthRow("Bridge launcher", status: viewModel.hookHealth.bridgeLauncher ? "Ready" : "Missing")
                healthRow("Launcher target", status: viewModel.hookHealth.launcherResolvesApp ? "Current app" : "Needs repair")
                healthRow("Socket", status: viewModel.hookHealth.socketReachable ? "Reachable" : "Unavailable")
                HStack {
                    Button("Refresh") { viewModel.refreshHookHealth() }
                    Button("Repair Hooks") { viewModel.repairHooks() }
                    Button(viewModel.selfTestRunning ? "Testing..." : "Test Pipeline") {
                        viewModel.runSelfTest()
                    }
                    .disabled(viewModel.selfTestRunning)
                    Spacer()
                }
                .padding(.top, 8)

                // The rows above say what is installed; this says whether it
                // works. Only shown once the user has asked.
                if let result = viewModel.selfTestResult {
                    if result.passed {
                        Text("Pipeline OK — the hook ran and ZackEyes received the event.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.failures, id: \.step) { failure in
                                Text(failure.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppColors.critical.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }

            settingsGroup("Support") {
                HStack {
                    Button("Export Diagnostics...", action: exportDiagnostics)
                    Spacer()
                }
            }

            settingsGroup("Remove") {
                HStack {
                    Button("Uninstall Integrations...", action: uninstallIntegrations)
                        .foregroundStyle(AppColors.critical.color)
                    Spacer()
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                appIcon.frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ZackEyes")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Version \(appVersion)")
                        .foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.open(Self.websiteURL)
                    } label: {
                        Text("zackeyes.vercel.app")
                            .font(.system(size: 12))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            settingsGroup("Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        if let version = updateChecker.availableVersion {
                            Text("Version \(version) is available")
                            Text(updateStatus)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("ZackEyes is up to date")
                            Text("Updates are checked automatically")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if updateChecker.availableVersion != nil {
                        Button(updateButtonTitle) { startUpdate() }
                            .disabled(isDownloading)
                    } else {
                        Button("Check Now") { updateChecker.checkNow() }
                    }
                }
            }
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondaryForeground)
            VStack(alignment: .leading, spacing: 12, content: content)
        }
        .padding(12)
        .background(surfaceBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(transparentBorder, lineWidth: 1)
        )
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 160, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func healthRow(_ title: String, status: String) -> some View {
        HStack {
            Image(systemName: status == "Ready" || status == "Current app" || status == "Reachable" || status == "Installed"
                ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status == "Ready" || status == "Current app" || status == "Reachable" || status == "Installed"
                    ? AppColors.success.color : AppColors.attention.color)
            Text(title)
            Spacer()
            Text(status).foregroundStyle(.secondary)
        }
    }

    private func agentStatus(_ status: HookHealthReport.AgentHooksStatus) -> String {
        switch status {
        case .installed: return "Installed"
        case .partial(let missing): return "Missing \(missing.count)"
        case .missing: return "Missing"
        case .notInstalled: return "Agent not found"
        case .unreadable: return "Unreadable"
        }
    }

    private func themeIcon(_ theme: BuddyTheme) -> some View {
        let symbol: String
        let tint: Color
        switch theme {
        case .rock:     symbol = "guitars.fill";   tint = .red
        case .f1:       symbol = "flag.checkered"; tint = .blue
        case .silicon:  symbol = "cpu";            tint = .purple
        case .shinchan: symbol = "pencil.tip.crop.circle.fill"; tint = .orange
        }
        return Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(tint)
            .frame(width: 28, height: 20)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = NSImage(named: "AppIcon") {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .padding(6)
                .foregroundStyle(accent)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = downloader.state { return true }
        return false
    }

    private var updateStatus: String {
        switch downloader.state {
        case .idle: return "Ready to download"
        case .downloading: return "Downloading..."
        case .ready: return "Downloaded and opened"
        case .failed(let message): return "Download failed: \(message)"
        }
    }

    private var updateButtonTitle: String {
        switch downloader.state {
        case .downloading: return "Downloading..."
        case .ready: return "Open Again"
        case .failed: return "Retry"
        case .idle: return "Download Update"
        }
    }

    private func startUpdate() {
        if let dmgURL = updateChecker.dmgURL {
            Task { await downloader.download(from: dmgURL) }
        } else if let releaseURL = updateChecker.releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    /// The persisted value is opacity; the control intentionally presents its
    /// inverse so moving right makes the overlay more transparent.
    private var overlayTransparency: Binding<Double> {
        Binding(
            get: { 1 - viewModel.timeOverlayOpacity },
            set: { viewModel.setTimeOverlayOpacity(1 - $0) }
        )
    }

    private func binding<Value: Sendable>(
        _ value: Value,
        _ setter: @escaping @MainActor @Sendable (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: { value }, set: { setter($0) })
    }
}
