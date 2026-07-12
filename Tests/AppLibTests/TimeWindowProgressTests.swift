import Foundation
import Testing
@testable import AppLib

struct TimeWindowProgressTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func fixedWindowDurations() {
        #expect(TimeWindowProgress.fiveHours == 18_000)
        #expect(TimeWindowProgress.sevenDays == 604_800)
    }

    @Test
    func elapsedFractionTracksWindowBoundaries() {
        let duration: TimeInterval = 100
        #expect(TimeWindowProgress.elapsedFraction(
            now: now, resetsAt: now.addingTimeInterval(duration), duration: duration
        ) == 0)
        #expect(TimeWindowProgress.elapsedFraction(
            now: now, resetsAt: now.addingTimeInterval(duration / 2), duration: duration
        ) == 0.5)
        #expect(TimeWindowProgress.elapsedFraction(
            now: now, resetsAt: now, duration: duration
        ) == 1)
    }

    @Test
    func elapsedFractionClampsOutsideWindow() {
        #expect(TimeWindowProgress.elapsedFraction(
            now: now, resetsAt: now.addingTimeInterval(150), duration: 100
        ) == 0)
        #expect(TimeWindowProgress.elapsedFraction(
            now: now, resetsAt: now.addingTimeInterval(-50), duration: 100
        ) == 1)
    }

    @Test
    func elapsedFractionRequiresResetAndPositiveDuration() {
        #expect(TimeWindowProgress.elapsedFraction(now: now, resetsAt: nil, duration: 100) == nil)
        #expect(TimeWindowProgress.elapsedFraction(now: now, resetsAt: now, duration: 0) == nil)
        #expect(TimeWindowProgress.elapsedFraction(now: now, resetsAt: now, duration: -.infinity) == nil)
    }

    @Test
    func longerElapsedProgressRendersBelowUsage() {
        #expect(
            TimeWindowProgress.layerOrder(elapsedFraction: 0.7, usageFraction: 0.4)
                == .belowUsage
        )
    }

    @Test
    func shorterElapsedProgressRendersAboveUsage() {
        #expect(
            TimeWindowProgress.layerOrder(elapsedFraction: 0.3, usageFraction: 0.4)
                == .aboveUsage
        )
    }

    @Test
    func equalProgressRendersTimeAboveUsage() {
        #expect(
            TimeWindowProgress.layerOrder(elapsedFraction: 0.4, usageFraction: 0.4)
                == .aboveUsage
        )
    }

    @Test
    func endpointPositionTracksBothFillAnchorsAndClamps() {
        let width: CGFloat = 200

        #expect(TimeWindowProgress.endpointPosition(
            fraction: 0, trackWidth: width, anchor: .leading
        ) == 0)
        #expect(TimeWindowProgress.endpointPosition(
            fraction: 0.5, trackWidth: width, anchor: .leading
        ) == 100)
        #expect(TimeWindowProgress.endpointPosition(
            fraction: 1, trackWidth: width, anchor: .leading
        ) == 200)

        #expect(TimeWindowProgress.endpointPosition(
            fraction: 0, trackWidth: width, anchor: .trailing
        ) == 200)
        #expect(TimeWindowProgress.endpointPosition(
            fraction: 0.5, trackWidth: width, anchor: .trailing
        ) == 100)
        #expect(TimeWindowProgress.endpointPosition(
            fraction: 1, trackWidth: width, anchor: .trailing
        ) == 0)
        #expect(TimeWindowProgress.endpointPosition(
            fraction: 2, trackWidth: width, anchor: .leading
        ) == 200)
    }

}
