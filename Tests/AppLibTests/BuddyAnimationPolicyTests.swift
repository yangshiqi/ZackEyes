import Testing
@testable import AppLib
import Shared

struct BuddyAnimationPolicyTests {
    @Test
    func reduceMotionDisablesEveryAnimationState() {
        #expect(BuddyAnimationPolicy.mode(
            state: .working,
            isWaiting: true,
            isSleeping: true,
            reduceMotion: true
        ) == .none)
    }

    @Test
    func normalModePreservesStateSpecificAnimation() {
        #expect(BuddyAnimationPolicy.mode(
            state: .waiting, isWaiting: true, isSleeping: false, reduceMotion: false
        ) == .waiting)
        #expect(BuddyAnimationPolicy.mode(
            state: .working, isWaiting: false, isSleeping: false, reduceMotion: false
        ) == .working)
        #expect(BuddyAnimationPolicy.mode(
            state: .idle, isWaiting: false, isSleeping: true, reduceMotion: false
        ) == .sleeping)
        #expect(BuddyAnimationPolicy.mode(
            state: .idle, isWaiting: false, isSleeping: false, reduceMotion: false
        ) == .resting)
    }
}
