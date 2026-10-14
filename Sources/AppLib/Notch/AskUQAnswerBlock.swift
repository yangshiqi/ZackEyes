import SwiftUI
import Shared

/// In-notch answer surface for AskUserQuestion (#260).
///
/// Rendered only when the answer-from-notch toggle is on — i.e. the pending
/// carries a live bridge responder (`answerableFromNotch`). Each question
/// shows its options (radio for single-select, checkboxes for multi-select);
/// Submit sends the answers through the bridge, no keystroke injection.
/// "Answer in terminal" is the escape hatch: it defers to CC's native UI
/// and jumps to the terminal tab.
struct AskUQAnswerBlock: View {
    let session: SessionInfo
    let pending: PendingPermission
    @ObservedObject var viewModel: NotchViewModel

    /// question text → selected option labels
    @State private var selections: [String: Set<String>] = [:]
    @State private var submitFailed = false

    private var questions: [PendingPermission.Question] { pending.questions }

    private var allAnswered: Bool {
        !questions.isEmpty && questions.allSatisfy { !(selections[$0.text]?.isEmpty ?? true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.activity.color)
                Text("Claude's Question")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.activity.color)
            }

            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                questionBlock(question)
            }

            if submitFailed {
                Text("Couldn't send the answer — answer in the terminal instead.")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.attention.color)
            }

            HStack(spacing: 8) {
                Button(action: submit) {
                    Text("Submit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AppColors.activity.color.opacity(allAnswered ? 0.85 : 0.3))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!allAnswered)

                Button(action: {
                    viewModel.deferAskUQToTerminal(for: session, requestId: pending.id)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Answer in terminal")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            Text("Unanswered questions return to the terminal after 2 minutes.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.top, 6)
        .padding(.leading, 16)
    }

    @ViewBuilder
    private func questionBlock(_ question: PendingPermission.Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                if let header = question.header {
                    Text("[\(header)]")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppColors.activity.color)
                }
                Text(question.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(question.options) { option in
                optionRow(question: question, option: option)
            }
        }
    }

    @ViewBuilder
    private func optionRow(
        question: PendingPermission.Question,
        option: PendingPermission.QuestionOption
    ) -> some View {
        let selected = selections[question.text]?.contains(option.label) ?? false
        Button(action: { toggleSelection(question: question, label: option.label) }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected
                      ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question.multiSelect ? "square" : "circle"))
                    .font(.system(size: 11))
                    .foregroundColor(selected ? AppColors.activity.color : .white.opacity(0.45))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .white : .white.opacity(0.85))
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? AppColors.activity.color.opacity(0.18) : Color.white.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleSelection(question: PendingPermission.Question, label: String) {
        var current = selections[question.text] ?? []
        if question.multiSelect {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = [label]
        }
        selections[question.text] = current
        submitFailed = false
    }

    private func submit() {
        // Sort labels for deterministic multi-select values.
        let answers = Dictionary(uniqueKeysWithValues: selections.map { key, value in
            (key, value.sorted().joined(separator: ","))
        })
        let ok = viewModel.submitAskUQAnswer(
            sessionId: session.id, requestId: pending.id, answers: answers
        )
        if !ok {
            // The request is gone or the answers didn't validate — don't
            // strand the user; jump to the terminal instead.
            submitFailed = true
            viewModel.activateTerminal(for: session)
        }
    }
}
