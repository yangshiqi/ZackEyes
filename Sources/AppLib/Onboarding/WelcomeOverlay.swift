import SwiftUI

/// First-launch welcome. Rendered on top of the expanded notch content when
/// `NotchViewModel.welcomeVisible == true`. Layout: horizontal pill — left
/// PixelAvatar bumps in; right title + subtitle fades in. No interaction;
/// auto-dismissed after 3s by `AppDelegate.maybeShowWelcome()`.
struct WelcomeOverlay: View {
    @State private var avatarScale: CGFloat = 0.0
    @State private var textOpacity: Double = 0.0

    var body: some View {
        HStack(spacing: 16) {
            PixelAvatar(seed: "zackeyes-welcome", size: 56)
                .scaleEffect(avatarScale)

            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to ZackEyes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("I live in your notch. Hover here to see me.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
            }
            .opacity(textOpacity)

            Spacer(minLength: 0)
        }
        .padding(20)
        // Horizontal positioning comes from the trailing Spacer above
        // (pushes content leading); .center here only has effect in the
        // vertical dimension — the welcome sits mid-panel, not top-left.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // Spring drives 0 → 1.0 with response 0.40s / damping 0.55 —
            // the underdamped curve naturally overshoots before settling,
            // no explicit keyframe needed.
            withAnimation(.spring(response: 0.40, dampingFraction: 0.55)) {
                avatarScale = 1.0
            }
            // Text fades in 0.10s after avatar starts so the bump lands first.
            withAnimation(.easeOut(duration: 0.30).delay(0.10)) {
                textOpacity = 1.0
            }
        }
    }
}
