import LineMapCore
import SwiftUI

/// The optional questions after a report. Each answer is saved as soon as it's
/// given, and every question can be skipped or answered "I can't tell" (FR-12).
struct QuestionSheet: View {
    @Environment(AppModel.self) private var model
    let question: Question

    var body: some View {
        switch question {
        case .lineSize(let target):
            OptionsView(
                id: "lineSize",
                title: target == .start ? "How long is the line?" : "How long is the line now?",
                subtitle: "Roughly how many people are ahead of you?",
                options: LineSize.allCases.map { (Labels.option($0), Answer.answered($0)) },
                cantTell: .cantTell,
                skip: .skipped
            ) { answer in
                model.answerLineSize(answer, for: target)
            }
        case .startOffset:
            OptionsView<StartOffset?>(
                id: "startOffset",
                title: "Been here a while?",
                subtitle: "We'll start your timer earlier.",
                options: [("Just got here", nil)] + StartOffset.allCases.map { offset -> (String, StartOffset?) in
                    (Labels.option(offset), offset)
                },
                cantTell: nil,
                skip: nil
            ) { offset in
                model.answerStartOffset(offset)
            }
        case .busyness(let report):
            OptionsView(
                id: "busyness",
                title: "How busy is it inside?",
                subtitle: "Compared with how big the bar is.",
                options: Busyness.allCases.map { (Labels.option($0), Answer.answered($0)) },
                cantTell: .cantTell,
                skip: .skipped
            ) { answer in
                model.answerBusyness(answer, for: report)
            }
        case .recalledWait(let report):
            OptionsView(
                id: "recalledWait",
                title: "How long did it take to get in?",
                subtitle: "Including the ID check and cover.",
                options: RecalledWait.allCases.map { (Labels.option($0), Answer.answered($0)) },
                cantTell: .cantTell,
                skip: .skipped
            ) { answer in
                model.answerRecalledWait(answer, for: report)
            }
        }
    }
}

/// A question with big one-tap answers (NFR-3).
struct OptionsView<Value: Hashable>: View {
    let id: String
    let title: String
    let subtitle: String
    let options: [(String, Value)]
    /// The "I can't tell" answer, or nil to leave it out.
    let cantTell: Value?
    /// The Skip answer, or nil to leave Skip out.
    let skip: Value?
    let onAnswer: (Value) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        onAnswer(option.1)
                    } label: {
                        Text(option.0).frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("option-\(index)")
                }

                HStack {
                    if let cantTell {
                        Button(Labels.cantTell) { onAnswer(cantTell) }
                            .accessibilityIdentifier("option-cant-tell")
                    }
                    Spacer()
                    if let skip {
                        Button(Labels.skip) { onAnswer(skip) }
                            .accessibilityIdentifier("option-skip")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            .padding(20)
        }
        .accessibilityIdentifier("question-\(id)")
    }
}
