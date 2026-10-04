import LineMapCore
import SwiftUI
import UIKit

/// The optional questions. Start line timer and I'm in ask nothing; Line size and
/// Adjust time open from the wait card, and Report conditions from the bar
/// sheet. Every answer can be left out or swiped away (FR-12).
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
                // The whole line, not just the people ahead (2026-10-04, see supabase/README.md).
                title: "How many people are in line?",
                options: LineSize.offered.map { (Labels.option($0), Answer.answered($0)) },
                skip: .skipped
            ) { answer in
                model.answerLineSize(answer)
            }
        case .adjustTime:
            AdjustTimeView()
        case .conditions(let barId):
            ConditionsForm(barId: barId)
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
    var subtitle: String? = nil
    let options: [(String, Value)]
    /// The Skip answer, or nil to leave Skip out.
    let skip: Value?
    /// The current answer, shown highlighted.
    var selected: Value? = nil
    let onAnswer: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestionHeader(title: title, subtitle: subtitle)

            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                OptionButton(title: option.0, isSelected: selected == option.1, id: "option-\(index)") {
                    onAnswer(option.1)
                }
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

/// Adjust time (FR-7): just started, ~5, ~10, or Other for a wheel of every
/// minute from 1 to 90. Changeable or undoable while the line is open.
struct AdjustTimeView: View {
    @Environment(AppModel.self) private var model
    @State private var showsWheel = false
    @State private var wheelMinutes = 15

    private var current: Int? { model.activeWait?.offsetMinutes }
    private var currentCustom: Int? { current.flatMap { StartOffset.presets.contains($0) ? nil : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestionHeader(title: "Adjust time",
                           subtitle: "How long were you in line before you started the timer?")

            if showsWheel {
                Picker("Minutes in line", selection: $wheelMinutes) {
                    ForEach(StartOffset.custom, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .pickerStyle(.wheel)
                .accessibilityIdentifier("adjust-wheel")

                Button {
                    model.adjustTime(minutes: wheelMinutes)
                } label: {
                    Text("Set \(wheelMinutes) min").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("adjust-set")

                Button("Back") { showsWheel = false }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
            } else {
                OptionButton(title: "Just started", isSelected: current == nil, id: "option-0") {
                    model.adjustTime(minutes: nil)
                }
                ForEach(Array(StartOffset.presets.enumerated()), id: \.element) { index, minutes in
                    OptionButton(title: Labels.startOffset(minutes: minutes), isSelected: current == minutes,
                                 id: "option-\(index + 1)") {
                        model.adjustTime(minutes: minutes)
                    }
                }
                OptionButton(title: currentCustom.map { "\(Labels.startOffset(minutes: $0))…" } ?? "Other",
                             isSelected: currentCustom != nil, id: "option-other") {
                    wheelMinutes = current ?? 15
                    showsWheel = true
                }
                .accessibilityHint("Pick any time up to \(StartOffset.maxMinutes) minutes")
            }
        }
        .padding(20)
        .sheetFitsContent()
        .accessibilityIdentifier("question-adjustTime")
    }
}

/// Report conditions (FR-11): line size and crowd on one screen, sent once.
/// Either answer can be left out; Send stays off until one is picked (FR-12).
struct ConditionsForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let barId: Int64
    @State private var lineSize: LineSize?
    @State private var busyness: Busyness?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestionHeader(title: "Report conditions",
                           subtitle: "\(model.bar(barId)?.name ?? "This bar"). Answer one or both.")

            Text("How many people are in line?")
                .font(.headline)
            ChoiceGrid(options: LineSize.offered, columns: typeSize.isAccessibilitySize ? 2 : 5,
                       selection: $lineSize, idPrefix: "line",
                       title: { Labels.shortOption($0) }, accessibilityTitle: { Labels.option($0) })

            Text("How busy is it inside?")
                .font(.headline)
                .padding(.top, 8)
            ChoiceGrid(options: Busyness.allCases, columns: typeSize.isAccessibilitySize ? 1 : 2,
                       selection: $busyness, idPrefix: "crowd",
                       title: { Labels.option($0) }, accessibilityTitle: { Labels.option($0) })

            Button {
                model.sendConditions(at: barId, lineSize: lineSize, busyness: busyness)
            } label: {
                Text("Send report").frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lineSize == nil && busyness == nil)
            .padding(.top, 8)
            .accessibilityIdentifier("conditions-send")

            Button("Cancel") { model.sheet = nil }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("conditions-cancel")
        }
        .padding(20)
        .sheetFitsContent()
        .accessibilityIdentifier("question-conditions")
    }
}

/// A title and, if given, a gray line under it.
private struct QuestionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        Text(title)
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, subtitle == nil ? 8 : 0)
        if let subtitle {
            Text(subtitle)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }
}

/// One big answer button, highlighted when it's the current answer.
private struct OptionButton: View {
    let title: String
    let isSelected: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : nil)
        .fontWeight(isSelected ? .semibold : .regular)
        .controlSize(.large)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// A grid of answer tiles where at most one is picked. Tapping the picked one
/// again clears it, since every answer is optional.
private struct ChoiceGrid<Value: Hashable>: View {
    let options: [Value]
    let columns: Int
    @Binding var selection: Value?
    let idPrefix: String
    let title: (Value) -> String
    let accessibilityTitle: (Value) -> String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let isSelected = selection == option
                Button {
                    selection = isSelected ? nil : option
                } label: {
                    Text(title(option))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                                    in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityTitle(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("\(idPrefix)-\(index)")
            }
        }
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
