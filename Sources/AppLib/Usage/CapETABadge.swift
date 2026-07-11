import SwiftUI

/// #86 — inline cap-ETA badge ("⚡ ~XXmin"), shared by every usage surface.
/// Renders nothing for the calm (`computing` / `safe`) states so a row keeps
/// its normal layout. Amber normally, red when urgent (≤30 min to cap).
/// `compact` shrinks it for the tight split-agent halves.
public struct CapETABadge: View {
    let eta: CapETA?
    var compact: Bool

    public init(eta: CapETA?, compact: Bool = false) {
        self.eta = eta
        self.compact = compact
    }

    public var body: some View {
        if let label = eta?.panelLabel {
            let tint = (eta?.isUrgent ?? false)
                ? AppColors.critical.color
                : AppColors.attention.color
            HStack(spacing: 2) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: compact ? 7 : 8, weight: .bold))
                Text(label)
                    .font(.system(size: compact ? 8 : 10, weight: .semibold))
            }
            .foregroundColor(tint)
            .padding(.horizontal, compact ? 4 : 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.16)))
        }
    }
}
