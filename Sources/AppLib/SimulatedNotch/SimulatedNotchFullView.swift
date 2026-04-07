import SwiftUI
import AppKit

/// Full-content view shown when the simulated notch is morphed into the
/// expanded panel. Layout:
///   - Top: 5h + 7d usage progress bars
///   - Below: scrollable session list
struct SimulatedNotchFullView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    @ObservedObject var modeStore: NotchModeStore
    var cornerRadius: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            usageHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                NotchExpandedView(viewModel: viewModel)
                    .background(Color.clear)
            }
        }
        .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
        .clipShape(NotchShape(cornerRadius: cornerRadius))
        .overlay(aboutOverlay)
    }

    /// About card overlay — semi-transparent backdrop + centered card
    /// with app icon, name, version, and OK button. Shown when
    /// `modeStore.isAboutShown == true`.
    @ViewBuilder
    private var aboutOverlay: some View {
        if modeStore.isAboutShown {
            ZStack {
                // Backdrop — tap to dismiss.
                Color.black.opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        modeStore.isAboutShown = false
                    }

                // Card — opaque, centered, fixed 280×200.
                VStack(spacing: 14) {
                    aboutIcon
                        .frame(width: 64, height: 64)

                    Text("ZackEyes")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))

                    Button("OK") {
                        modeStore.isAboutShown = false
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .frame(width: 280, height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.12))
                )
                .contentShape(Rectangle())
                .onTapGesture { /* no-op: prevent backdrop dismiss when tapping card */ }
            }
            .transition(.opacity)
        }
    }

    /// Icon for the About card. Tries to load the bundle's AppIcon image;
    /// falls back to a SF Symbol if it isn't found.
    @ViewBuilder
    private var aboutIcon: some View {
        if let nsImage = NSImage(named: "AppIcon") {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    /// Version string from Info.plist's CFBundleShortVersionString.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Usage header

    private var usageHeader: some View {
        let snap = usageTracker.snapshot
        return VStack(spacing: 8) {
            usageBar(
                label: "5h",
                usedPct: snap.fiveHourUsedPct,
                resetsAt: snap.fiveHourResetsAt,
                trailing: { gearMenu }
            )
            usageBar(
                label: "7d",
                usedPct: snap.sevenDayUsedPct,
                resetsAt: snap.sevenDayResetsAt
            )
        }
    }

    /// Settings dropdown menu — anchored to the gear icon at the right
    /// of the 5h row in the header. Two items: About and Quit.
    private var gearMenu: some View {
        Menu {
            Button("About ZackEyes…") {
                modeStore.isAboutShown = true
            }
            Divider()
            Button("Quit ZackEyes") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func usageBar<Trailing: View>(
        label: String,
        usedPct: Double?,
        resetsAt: Date?,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let used = usedPct ?? 0
        let remaining = max(0, 100 - used)
        let color = barColor(for: used)
        let hasData = usedPct != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, alignment: .leading)

                if hasData {
                    Text(String(format: "%.0f%% remaining", remaining))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("no data")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer(minLength: 0)

                if let reset = relativeReset(resetsAt) {
                    Text("resets in \(reset)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                trailing()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 6)
                    if hasData {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(used / 100), height: 6)
                    }
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Helpers

    /// Green when plenty remaining → orange → red.
    private func barColor(for used: Double) -> Color {
        switch used {
        case ..<50: return Color(red: 0.31, green: 0.80, blue: 0.77)  // teal
        case ..<85: return Color(red: 0.96, green: 0.65, blue: 0.14)  // orange
        default:    return Color(red: 0.95, green: 0.30, blue: 0.30)  // red
        }
    }

    private func relativeReset(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let hours = Int(interval) / 3600
        let mins = (Int(interval) % 3600) / 60
        let days = hours / 24
        if days >= 1 { return "\(days)d" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
