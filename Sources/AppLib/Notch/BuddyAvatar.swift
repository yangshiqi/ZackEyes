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
    @State private var sleepDroop: Double = 0    // idle tilt (falling asleep)

    // Three Zs, each with its own phase offset
    @State private var z1Phase: Double = 0
    @State private var z2Phase: Double = 0.33
    @State private var z3Phase: Double = 0.66

    private let isIdle: Bool
    init(seed: String, state: SessionState, isWaiting: Bool, size: CGFloat = 32) {
        self.seed = seed
        self.state = state
        self.isWaiting = isWaiting
        self.size = size
        self.isIdle = (state == .idle || state == .stopped) && !isWaiting
    }

    var body: some View {
        ZStack {
            PixelAvatar(seed: seed, size: size)
                .offset(x: shake, y: bounce + rockBounce)
                .scaleEffect(breathe)
                .rotationEffect(.degrees(rockTilt + shake * 3 + sleepDroop))
                .opacity(isIdle ? 0.55 : 1.0)

            // Sleep "Zzz" — three floating letters of increasing size
            if isIdle {
                zFloat(phase: z1Phase, size: size * 0.28, xOffset: 0.40, delay: 0)
                zFloat(phase: z2Phase, size: size * 0.34, xOffset: 0.50, delay: 0.4)
                zFloat(phase: z3Phase, size: size * 0.42, xOffset: 0.62, delay: 0.8)
            }
        }
        .frame(width: size * 1.8, height: size * 1.8)
        .onAppear { applyAnimation() }
        .onChange(of: state) { _, _ in applyAnimation() }
        .onChange(of: isWaiting) { _, _ in applyAnimation() }
    }

    @ViewBuilder
    private func zFloat(phase: Double, size fontSize: CGFloat, xOffset: CGFloat, delay: Double) -> some View {
        Text("z")
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(1.0 - phase))
            .offset(
                x: size * xOffset + CGFloat(phase) * 4,
                y: -size * 0.25 - CGFloat(phase) * size * 0.5
            )
    }

    private func applyAnimation() {
        // Reset all
        withAnimation(.linear(duration: 0)) {
            bounce = 0
            shake = 0
            rockTilt = 0
            rockBounce = 0
            breathe = 1.0
            sleepDroop = 0
            z1Phase = 0
            z2Phase = 0
            z3Phase = 0
        }

        if isWaiting {
            // Panic shake
            withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) {
                shake = 1.8
            }
        } else if state == .working {
            // Rock out — fast headbang
            withAnimation(.easeInOut(duration: 0.22).repeatForever(autoreverses: true)) {
                rockTilt = -14
                rockBounce = 1.5
            }
        } else {
            // Sleeping — buddy drooping + slow breathing + cascading Zzz
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                sleepDroop = 8
            }
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                breathe = 1.04
            }
            // Stagger the three Zs so they drift up in sequence
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                z1Phase = 1
            }
            withAnimation(.linear(duration: 2.4).delay(0.8).repeatForever(autoreverses: false)) {
                z2Phase = 1
            }
            withAnimation(.linear(duration: 2.4).delay(1.6).repeatForever(autoreverses: false)) {
                z3Phase = 1
            }
        }
    }
}
