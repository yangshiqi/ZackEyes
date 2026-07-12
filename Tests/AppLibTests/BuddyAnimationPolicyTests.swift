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
    func inactiveContentDisablesEveryAnimationState() {
        #expect(BuddyAnimationPolicy.mode(
            state: .working,
            isWaiting: false,
            isSleeping: false,
            reduceMotion: false,
            animationsEnabled: false
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

    @Test
    func reduceMotionProvidesDistinctStaticStateCues() {
        #expect(BuddyAnimationPolicy.staticCue(
            state: .waiting, isWaiting: true, isSleeping: false, reduceMotion: true
        ) == .waiting)
        #expect(BuddyAnimationPolicy.staticCue(
            state: .working, isWaiting: false, isSleeping: false, reduceMotion: true
        ) == .working)
        #expect(BuddyAnimationPolicy.staticCue(
            state: .idle, isWaiting: false, isSleeping: true, reduceMotion: true
        ) == .sleeping)
        #expect(BuddyAnimationPolicy.staticCue(
            state: .idle, isWaiting: false, isSleeping: false, reduceMotion: true
        ) == .resting)
        #expect(BuddyAnimationPolicy.staticCue(
            state: .working, isWaiting: false, isSleeping: false, reduceMotion: false
        ) == nil)
    }
}
