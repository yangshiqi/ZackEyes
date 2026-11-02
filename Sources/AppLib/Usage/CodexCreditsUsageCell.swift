import SwiftUI

/// Replaces a Codex quota cell while the account is using extra credits.
/// There is no balance progress bar because Codex reports no pool total.
struct CodexCreditsUsageCell: View {
    let credits: CodexCredits
    var showsBalance = true
    var compact = false
    var resetsAt: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: compact ? 4 : 6) {
                Text(compact ? "X" : "Codex")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentBadge.accentColor(for: .codex))
                Text(showsBalance ? credits.balanceLabel : (compact ? "Using credits" : "Using extra credits"))
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(showsBalance ? AppColors.activity.color : AppColors.attention.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(showsBalance ? "Extra credits" : resetLabel)
                .font(.system(size: compact ? 9 : 10))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Using extra Codex credits. Balance: \(credits.balanceLabel). \(resetLabel)")
        .accessibilityElement(children: .combine)
    }

    private var resetLabel: String {
        if let reset = resetsAt?.usageResetDisplay { return "Plan resets in \(reset)" }
        return "Plan allowance exhausted"
    }
}
