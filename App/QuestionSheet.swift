import LineMapCore
import SwiftUI

/// The optional questions. I'm in line asks nothing; Line size and Adjust time
/// open from the wait card. Each answer is saved as soon as it's given, and
/// every question can be skipped or swiped away (FR-12).
///
/// Not offered (Max's call, 2026-10-01): "Can't see the end" (line size code 5)
/// and "I can't tell". Their stored codes stay reserved and keep their meaning.
struct QuestionSheet: View {
    @Environment(AppModel.self) private var model
    let question: Question

    var body: some View {
        switch question {
        case .lineSize:
            OptionsView(
                id: "lineSize",
                title: "How long is the line?",
                subtitle: "Roughly how many people are ahead of you?",
                options: LineSize.offered.map { (Labels.option($0), Answer.answered($0)) },
                skip: .skipped
            ) { answer in
                model.answerLineSize(answer)
            }
        case .adjustTime:
            OptionsView<StartOffset?>(
                id: "adjustTime",
                title: "Adjust time",
                subtitle: "How long were you in line before you started the timer?",
                options: [("Just started", nil)] + StartOffset.allCases.map { offset -> (String, StartOffset?) in
                    (Labels.option(offset), offset)
                },
                skip: nil,
                selected: .some(model.activeWait?.offset)
            ) { offset in
                model.adjustTime(offset)
            }
        case .busyness(let report):
            OptionsView(
                id: "busyness",
                title: "How busy is it inside?",
                subtitle: "Compared with how big the bar is.",
                options: Busyness.allCases.map { (Labels.option($0), Answer.answered($0)) },
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
                skip: .skipped
            ) { answer in
                model.answerRecalledWait(answer, for: report)
            }
        }
    }
}

extension LineSize {
    /// The line sizes the app offers. `.cantSeeEnd` stays a valid stored code.
    static var offered: [LineSize] {
        allCases.filter { $0 != .cantSeeEnd }
    }
}

/// A question with big one-tap answers (NFR-3).
struct OptionsView<Value: Hashable>: View {
    let id: String
    let title: String
    let subtitle: String
    let options: [(String, Value)]
    /// The Skip answer, or nil to leave Skip out.
    let skip: Value?
    /// The current answer, shown highlighted.
    var selected: Value? = nil
    let onAnswer: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isSelected = selected == option.1
                Button {
                    onAnswer(option.1)
                } label: {
                    Text(option.0).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : nil)
                .fontWeight(isSelected ? .semibold : .regular)
                .controlSize(.large)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("option-\(index)")
            }

            if let skip {
                HStack {
                    Spacer()
                    Button(Labels.skip) { onAnswer(skip) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("option-skip")
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .sheetFitsContent()
        .accessibilityIdentifier("question-\(id)")
    }
}

/// Sizes a sheet to its content instead of letting it pull to the top of the
/// screen. Taller content (large text sizes) scrolls.
struct FitsContentHeight: ViewModifier {
    @State private var contentHeight: CGFloat = 320

    func body(content: Content) -> some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // The sheet's height already includes the bottom safe area.
        .presentationDetents([.height(contentHeight)])
    }
}

extension View {
    func sheetFitsContent() -> some View {
        modifier(FitsContentHeight())
    }
}
