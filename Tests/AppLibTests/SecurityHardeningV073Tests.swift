import Testing
@testable import AppLib

/// Regression tests for the v0.7.3 security hardening (rescan findings).
struct SecurityHardeningV073Tests {

    // T-8: untrusted token counts are clamped so accumulating many records
    // can't overflow Int and trap the process.
    @Test func clampTokens_clampsHugeAndNegative() {
        #expect(UsageTracker.clampTokens(Int.max) == 1_000_000_000)
        #expect(UsageTracker.clampTokens(-5) == 0)
        #expect(UsageTracker.clampTokens(12_345) == 12_345)
        #expect(UsageTracker.clampTokens(0) == 0)
    }

    // T-2: the size/symlink gate that the Claude path uses is now reusable by
    // the sibling readers (codex scan, TaskExtractor).
    @Test func shouldScanTranscript_skipsSymlinksAndOversize() {
        #expect(UsageTracker.shouldScanTranscript(isSymbolicLink: false, fileSize: 1_000))
        #expect(!UsageTracker.shouldScanTranscript(isSymbolicLink: true, fileSize: 1_000))
        #expect(!UsageTracker.shouldScanTranscript(
            isSymbolicLink: false, fileSize: UsageTracker.maxTranscriptBytes + 1))
    }

    // T-4: only a simple .dmg filename (no path separators / parent refs) is
    // accepted before it is used to build the reconstructed download URL.
    @Test func isSafeAssetName_rejectsTraversalAcceptsPlain() {
        #expect(UpdateChecker.isSafeAssetName("ZackEyes-0.7.3.dmg"))
        #expect(!UpdateChecker.isSafeAssetName("../evil.dmg"))
        #expect(!UpdateChecker.isSafeAssetName("a/b.dmg"))
        #expect(!UpdateChecker.isSafeAssetName("x\\y.dmg"))
        #expect(!UpdateChecker.isSafeAssetName("ZackEyes.zip"))
        #expect(!UpdateChecker.isSafeAssetName(""))
    }
}
