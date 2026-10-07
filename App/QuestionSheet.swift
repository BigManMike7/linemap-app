import LineMapCore
import SwiftUI
import UIKit

/// The optional questions. Start line timer and I'm in ask nothing; Line size and
/// Adjust time open from the wait card, and Report line size from the bar
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
            LineSizeView(lineSize: model.activeWait?.lineSize)
        case .adjustTime:
            AdjustTimeView(minutes: model.activeWait?.offsetMinutes ?? 0)
        case .conditions(let barId):
            ConditionsForm(barId: barId)
        }
    }
}

/// Line size (FR-6): one wheel of the offered sizes, starting on the last
/// answer in this wait. Save, gray while the wheel spins, sends it, even
/// unchanged (a fresh report); swiping the sheet away sends nothing.
struct LineSizeView: View {
    @Environment(AppModel.self) private var model
    @State private var lineSize: LineSize
    @State private var motion = WheelMotion()

    init(lineSize: LineSize?) {
        _lineSize = State(initialValue: lineSize ?? .nobody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The whole line, not just the people ahead (2026-10-04, see supabase/README.md).
            QuestionHeader(title: "How many people are in line?")

            Wheel(label: "People in line", options: LineSize.offered, selection: $lineSize,
                  title: { Labels.option($0) }, motion: motion, id: "line-wheel")

            SaveButton(id: "line-save", wheelMoving: motion.isMoving) {
                model.answerLineSize(lineSize, wheelMoving: motion.isMovingNow)
            }
        }
        .padding(20)
        .sheetFitsContent()
        .accessibilityIdentifier("question-lineSize")
    }
}

/// Adjust time (FR-7): one wheel of every minute from 0 to 90, starting on the
/// current time. Save sends it, and 0 undoes it; swiping the sheet away
/// changes nothing.
struct AdjustTimeView: View {
    @Environment(AppModel.self) private var model
    @State private var minutes: Int
    @State private var motion = WheelMotion()

    init(minutes: Int) {
        _minutes = State(initialValue: minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestionHeader(title: "Adjust time",
                           subtitle: "How long were you in line before you started the timer?")

            Wheel(label: "Minutes in line", options: Array(StartOffset.choices), selection: $minutes,
                  title: { Labels.startOffset(minutes: $0) }, motion: motion, id: "adjust-wheel")

            SaveButton(id: "adjust-save", wheelMoving: motion.isMoving) {
                model.adjustTime(minutes: minutes, wheelMoving: motion.isMovingNow)
            }
        }
        .padding(20)
        .sheetFitsContent()
        .accessibilityIdentifier("question-adjustTime")
    }
}

/// Report line size (FR-11): one line-size answer, sent once. Send stays off
/// until a size is picked. (Until 2026-10-06 this was Report conditions, which
/// also asked how busy it was inside.)
struct ConditionsForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let barId: Int64
    @State private var lineSize: LineSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestionHeader(title: "Report line size",
                           subtitle: model.bar(barId)?.name ?? "This bar")

            Text("How many people are in line?")
                .font(.headline)
            ChoiceGrid(options: LineSize.offered, columns: typeSize.isAccessibilitySize ? 2 : 3,
                       selection: $lineSize, idPrefix: "line",
                       title: { Labels.shortOption($0) }, accessibilityTitle: { Labels.option($0) })

            Button {
                model.sendConditions(at: barId, lineSize: lineSize)
            } label: {
                Text("Send report").frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lineSize == nil)
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

/// The big Save button under a wheel, gray until the wheel stops, since the
/// wheel picks only then. The sheet closes and a short message or a haptic
/// confirms the answer was sent (FR-42).
private struct SaveButton: View {
    let id: String
    let wheelMoving: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Save").frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(wheelMoving)
        .padding(.top, 4)
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
