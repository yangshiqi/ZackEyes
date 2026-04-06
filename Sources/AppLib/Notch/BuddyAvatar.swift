import SwiftUI
import Shared

/// Animated pixel avatar with personality — bounces when working, sleeps when idle, shakes when waiting.
struct BuddyAvatar: View {
    let seed: String
    let state: SessionState
    let isWaiting: Bool   // has pending permission
    var size: CGFloat = 32

    @State private var bounce: CGFloat = 0
    @State private var breathe: CGFloat = 1.0
    @State private var shake: CGFloat = 0
    @State private var rockTilt: Double = 0      // headbang rotation
    @State private var rockBounce: CGFloat = 0   // headbang vertical
    @State private var zOpacity: Double = 0.0

    var body: some View {
        ZStack {
            PixelAvatar(seed: seed, size: size)
                .offset(x: shake, y: bounce + rockBounce)
                .scaleEffect(breathe)
                .rotationEffect(.degrees(rockTilt + shake * 3))

            // Sleep "Z" indicator (shown only when idle)
            if state == .idle && !isWaiting {
                Text("z")
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(zOpacity))
                    .offset(x: size * 0.45, y: -size * 0.35)
            }
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .onAppear { applyAnimation() }
        .onChange(of: state) { _, _ in applyAnimation() }
        .onChange(of: isWaiting) { _, _ in applyAnimation() }
    }

    private func applyAnimation() {
        // Reset — halt all ongoing animations
        withAnimation(.linear(duration: 0)) {
            bounce = 0
            shake = 0
            rockTilt = 0
            rockBounce = 0
            breathe = 1.0
            zOpacity = 0.0
        }

        if isWaiting {
            // Panic shake — quick left/right
            withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) {
                shake = 1.8
            }
        } else if state == .working {
            // Rock out — fast headbang: tilt + drop
            withAnimation(.easeInOut(duration: 0.22).repeatForever(autoreverses: true)) {
                rockTilt = -14
                rockBounce = 1.5
            }
        } else {
            // Sleeping — slow breathing + fading Z
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathe = 1.06
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                zOpacity = 0.8
            }
        }
    }
}
