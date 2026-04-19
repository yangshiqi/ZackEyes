import SwiftUI

/// First-launch welcome content. Rendered on top of the expanded notch
/// when `NotchViewModel.welcomeVisible == true`. Layout: horizontal pill —
/// left BuddyAvatar headbangs continuously (state forced to `.working`
/// to trigger the existing rock-out animation); right side types the
/// title one character at a time, then fades in the subtitle. The whole
/// overlay does a spring entrance to sync with the chime. No interaction;
/// auto-dismissed after 3s by `AppDelegate.maybeShowWelcome()`.
///
/// Pure content view — callers supply the background + clip shape so each
/// surface (real notch = RoundedRectangle, simulated notch = NotchShape)
/// can use the silhouette that matches its panel.
struct WelcomeOverlay: View {
    @State private var entranceScale: CGFloat = 0.92
    @State private var entranceOpacity: Double = 0.0
    @State private var displayedTitle: String = ""
    @State private var subtitleOpacity: Double = 0.0

    private let fullTitle = "Welcome to ZackEyes"
    private let charInterval: Double = 0.045  // 45ms per char → 19 chars ≈ 0.85s

    var body: some View {
        HStack(spacing: 16) {
            BuddyAvatar(
                seed: "zackeyes-welcome",
                state: .working,   // forces the headbang animation loop
                isWaiting: false,
                size: 48
            )

            VStack(alignment: .leading, spacing: 4) {
                // minHeight keeps the subtitle from jumping as chars are typed.
                Text(displayedTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(minHeight: 18, alignment: .leading)
                Text("I live in your notch. Hover here to see me.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                    .opacity(subtitleOpacity)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        // Horizontal positioning comes from the trailing Spacer above
        // (pushes content leading); .center here only has effect in the
        // vertical dimension — the welcome sits mid-panel, not top-left.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .scaleEffect(entranceScale)
        .opacity(entranceOpacity)
        .onAppear {
            // Entrance: spring 0.92 → 1.0 with a small overshoot, in sync
            // with the chime (AppDelegate plays the sound right after
            // flipping viewModel.welcomeVisible = true).
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                entranceScale = 1.0
                entranceOpacity = 1.0
            }
            typeTitle()
            // Subtitle fades in after the title finishes typing.
            let subtitleDelay = charInterval * Double(fullTitle.count) + 0.15
            withAnimation(.easeOut(duration: 0.35).delay(subtitleDelay)) {
                subtitleOpacity = 1.0
            }
        }
    }

    private func typeTitle() {
        Task { @MainActor in
            for i in 1...fullTitle.count {
                try? await Task.sleep(for: .seconds(charInterval))
                let end = fullTitle.index(fullTitle.startIndex, offsetBy: i)
                displayedTitle = String(fullTitle[..<end])
            }
        }
    }
}
