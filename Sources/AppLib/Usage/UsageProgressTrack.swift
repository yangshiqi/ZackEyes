import SwiftUI

enum TimeWindowProgress {
    enum LayerOrder {
        case belowUsage
        case aboveUsage
    }

    static let fiveHours: TimeInterval = 5 * 60 * 60
    static let sevenDays: TimeInterval = 7 * 24 * 60 * 60

    static func elapsedFraction(
        now: Date,
        resetsAt: Date?,
        duration: TimeInterval
    ) -> Double? {
        guard duration.isFinite, duration > 0, let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return max(0, min(1, 1 - remaining / duration))
    }

    static func layerOrder(elapsedFraction: Double, usageFraction: Double) -> LayerOrder {
        elapsedFraction > usageFraction ? .belowUsage : .aboveUsage
    }

    static func endpointPosition(
        fraction: Double,
        trackWidth: CGFloat,
        anchor: ProgressFillAnchor
    ) -> CGFloat {
        let clamped = CGFloat(max(0, min(1, fraction)))
        return anchor == .leading ? trackWidth * clamped : trackWidth * (1 - clamped)
    }
}

/// Shared quota usage track with an optional elapsed-window time layer.
struct UsageProgressTrack: View {
    let fillFraction: Double
    let fillAnchor: ProgressFillAnchor
    let hasData: Bool
    let usageColor: Color
    let timeMode: TimeProgressMode
    let progressMode: ProgressMode
    let leftProgressDirection: LeftProgressDirection
    let timeOverlayOpacity: Double
    let resetsAt: Date?
    let windowDuration: TimeInterval
    var height: CGFloat = 6

    private let timeColor = AppColors.timeMarker.color
    private let overlapColor = AppColors.timeOverlay.color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.white.opacity(0.10))

                if timeMode == .overlap, resetsAt != nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let elapsed = TimeWindowProgress.elapsedFraction(
                            now: context.date,
                            resetsAt: resetsAt,
                            duration: windowDuration
                        ) {
                            overlapLayers(elapsed: elapsed, width: geometry.size.width)
                        }
                    }
                } else {
                    usageLayer(width: geometry.size.width)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
            .overlay(alignment: .leading) {
                if timeMode == .icon, resetsAt != nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let elapsed = TimeWindowProgress.elapsedFraction(
                            now: context.date,
                            resetsAt: resetsAt,
                            duration: windowDuration
                        ) {
                            clockMarker(elapsed: elapsed, width: geometry.size.width)
                        }
                    }
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func overlapLayers(elapsed: Double, width: CGFloat) -> some View {
        let time = ProgressPresentation(
            usedFraction: elapsed,
            mode: progressMode,
            leftDirection: leftProgressDirection
        )
        let order = TimeWindowProgress.layerOrder(
            elapsedFraction: time.fraction,
            usageFraction: hasData ? clampedFill : 0
        )

        ZStack(alignment: .leading) {
            if order == .belowUsage {
                timeLayer(presentation: time, width: width)
            }
            usageLayer(width: width)
            if order == .aboveUsage {
                timeLayer(presentation: time, width: width)
            }
        }
    }

    @ViewBuilder
    private func usageLayer(width: CGFloat) -> some View {
        if hasData {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(usageColor)
                .frame(width: width * CGFloat(clampedFill), height: height)
                .frame(width: width, height: height, alignment: alignment(for: fillAnchor))
        }
    }

    @ViewBuilder
    private func timeLayer(presentation: ProgressPresentation, width: CGFloat) -> some View {
        let overlayOpacity = TimeOverlayOpacity.normalized(timeOverlayOpacity)
        if overlayOpacity > 0 {
            let boundaryOpacity = TimeOverlayOpacity.boundaryOpacity(for: overlayOpacity)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(overlapColor.opacity(overlayOpacity))
                    .frame(width: width * CGFloat(presentation.fraction), height: height)
                    .overlay {
                        RoundedRectangle(cornerRadius: height / 2)
                            .stroke(overlapColor.opacity(boundaryOpacity), lineWidth: 1)
                    }
                    .frame(width: width, height: height, alignment: alignment(for: presentation.anchor))

            }
        }
    }

    private func clockMarker(elapsed: Double, width: CGFloat) -> some View {
        let presentation = ProgressPresentation(
            usedFraction: elapsed,
            mode: progressMode,
            leftDirection: leftProgressDirection
        )
        let iconSize = max(9, height + 4)
        let radius = iconSize / 2
        let endpoint = TimeWindowProgress.endpointPosition(
            fraction: presentation.fraction,
            trackWidth: width,
            anchor: presentation.anchor
        )
        let centerX = min(max(radius, endpoint), max(radius, width - radius))

        return ZStack {
            Image(systemName: "clock.fill")
                .foregroundStyle(timeColor)

            // Remove only the band crossing the track, then put the clock
            // outline back in that band. The underlying quota bar is untouched.
            Image(systemName: "clock.fill")
                .foregroundStyle(Color.black)
                .mask(Rectangle().frame(height: height))
                .blendMode(.destinationOut)

            Image(systemName: "clock")
                .foregroundStyle(timeColor)
                .mask(Rectangle().frame(height: height))
        }
        .font(.system(size: iconSize, weight: .semibold))
        .frame(width: iconSize, height: iconSize)
        .compositingGroup()
        .offset(x: centerX - radius)
    }

    private var clampedFill: Double {
        max(0, min(1, fillFraction))
    }

    private func alignment(for anchor: ProgressFillAnchor) -> Alignment {
        anchor == .leading ? .leading : .trailing
    }
}
