import Testing
import Foundation
@testable import AppLib
import Shared

/// #42 — make a failed click-to-jump observable.
///
/// Scoped deliberately. The issue proposed five matching improvements taken
/// from a competitor's changelog, none with a reproducible failure behind it.
/// The one defect that could be demonstrated in this codebase is that
/// `activateTerminalDirectly`'s `Bool` was discarded, so a click that matched
/// nothing did nothing, reported nothing, and left no trace.
struct JumpDiagnosticsTests {

    // MARK: - Classification

    @Test func noPidAndNoCwdIsUnlocatable() {
        #expect(JumpDiagnostics.classify(
            hadPid: false, hadCwd: false, accessibilityTrusted: true) == .noTarget)
    }

    /// Permission outranks "no matching window": with AX denied the search
    /// could not have succeeded however good the matching is, so reporting
    /// the symptom instead of the cause would send the user hunting the wrong
    /// thing.
    @Test func deniedAccessibilityOutranksNoMatch() {
        #expect(JumpDiagnostics.classify(
            hadPid: true, hadCwd: true, accessibilityTrusted: false) == .accessibilityDenied)
        #expect(JumpDiagnostics.classify(
            hadPid: false, hadCwd: true, accessibilityTrusted: false) == .accessibilityDenied)
    }

    /// ...but a session we cannot locate at all is unlocatable regardless of
    /// permission — granting Accessibility would not help.
    @Test func noTargetOutranksAccessibility() {
        #expect(JumpDiagnostics.classify(
            hadPid: false, hadCwd: false, accessibilityTrusted: false) == .noTarget)
    }

    @Test func aLocatableTargetWithPermissionIsJustNoMatch() {
        #expect(JumpDiagnostics.classify(
            hadPid: true, hadCwd: false, accessibilityTrusted: true) == .noMatchingWindow)
        #expect(JumpDiagnostics.classify(
            hadPid: false, hadCwd: true, accessibilityTrusted: true) == .noMatchingWindow)
    }

    // MARK: - Labels

    @Test func everyReasonHasBothLabels() {
        for reason in [JumpFailureReason.noTarget,
                       .accessibilityDenied,
                       .noMatchingWindow] {
            #expect(!reason.shortLabel.isEmpty)
            #expect(!reason.traceLabel.isEmpty)
            // Card labels share a crowded row.
            #expect(reason.shortLabel.count <= 32)
            // Trace lines are grepped in support bundles.
            #expect(reason.traceLabel.hasPrefix("jump:"))
        }
    }

    /// The permission label must name the thing the user has to go and grant,
    /// otherwise it is no more actionable than "it didn't work".
    @Test func accessibilityLabelNamesThePermission() {
        #expect(JumpFailureReason.accessibilityDenied.shortLabel.contains("Accessibility"))
    }

    // MARK: - Store recording

    @MainActor
    private func store() -> SessionStore {
        let s = SessionStore()
        s.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", agent: .claude,
                                  sessionId: "s1", cwd: "/tmp/proj"))
        return s
    }

    @MainActor
    @Test func failureIsRecorded() {
        let s = store()
        s.recordJumpOutcome(sessionId: "s1", failure: .noMatchingWindow)
        #expect(s.sessions["s1"]?.jumpFailureReason == .noMatchingWindow)
        #expect(s.sessions["s1"]?.recentlyFailedJump() == true)
    }

    /// A card that failed once and then worked must stop accusing itself.
    @MainActor
    @Test func successClearsAPreviousFailure() {
        let s = store()
        s.recordJumpOutcome(sessionId: "s1", failure: .noMatchingWindow)
        s.recordJumpOutcome(sessionId: "s1", failure: nil)
        #expect(s.sessions["s1"]?.jumpFailureReason == nil)
        #expect(s.sessions["s1"]?.recentlyFailedJump() == false)
    }

    /// The marker answers "I just clicked and nothing happened", which stops
    /// being a live question quickly.
    @MainActor
    @Test func theMarkerExpires() {
        var session = SessionInfo(id: "s", cwd: "/tmp")
        let now = Date()
        session.jumpFailureReason = .noMatchingWindow
        session.jumpFailedAt = now.addingTimeInterval(-9)
        #expect(session.recentlyFailedJump(now: now) == false)
        session.jumpFailedAt = now.addingTimeInterval(-2)
        #expect(session.recentlyFailedJump(now: now) == true)
    }

    @MainActor
    @Test func aSessionThatNeverFailedShowsNothing() {
        #expect(store().sessions["s1"]?.recentlyFailedJump() == false)
    }

    @MainActor
    @Test func recordingForAnUnknownSessionIsSafe() {
        let s = SessionStore()
        s.recordJumpOutcome(sessionId: "ghost", failure: .noTarget)
        #expect(s.sessions["ghost"] == nil)
    }
}
