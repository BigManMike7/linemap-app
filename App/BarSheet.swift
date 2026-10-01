import LineMapCore
import SwiftUI

/// A bar's line, wait, crowd, and freshness, with the report buttons (FR-3).
struct BarSheet: View {
    @Environment(AppModel.self) private var model
    let bar: Bar
    @State private var confirmsNewLine = false

    private var isInLineHere: Bool { model.activeWait?.barId == bar.id }
    private var isInLineElsewhere: Bool { model.activeWait != nil && !isInLineHere }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    summary(BarSummary(estimate: model.estimate(for: bar.id), now: context.date))
                }
                actions
            }
            .padding(20)
        }
        .accessibilityIdentifier("bar-sheet")
        .onAppear { model.logBarView(bar) }
        .confirmationDialog(
            "Start a new line here?",
            isPresented: $confirmsNewLine,
            titleVisibility: .visible
        ) {
            Button("Start new line") { model.startLine(at: bar) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your timer at \(model.activeWaitBar?.name ?? "the other bar") will stop.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bar.name)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(bar.address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summary(_ summary: BarSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = summary.status {
                Text(status)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("bar-status")
            } else {
                InfoRow(title: "Line", systemImage: "person.3.sequence", line: summary.lineSize)
                InfoRow(title: "Wait", systemImage: "clock", line: summary.wait)
                InfoRow(title: "Crowd", systemImage: "person.2.wave.2", line: summary.busyness)
            }
            if let freshness = summary.freshness {
                Text(freshness)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("This looks wrong") {
                model.sendFeedback(for: bar)
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("looks-wrong-button")
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if isInLineHere {
                Label("You're in line here. Use the timer card when you get in.", systemImage: "timer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    if isInLineElsewhere {
                        confirmsNewLine = true
                    } else {
                        model.startLine(at: bar)
                    }
                } label: {
                    Text("I'm in line").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Starts a timer for your wait")
                .accessibilityIdentifier("in-line-button")
            }
            Button {
                model.reportInside(at: bar)
            } label: {
                Text(isInLineHere ? "I'm in" : "I'm inside").frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("inside-button")
        }
        .controlSize(.large)
    }
}

/// One line of the bar sheet: an icon, a title, and a value that grays out when older.
struct InfoRow: View {
    let title: String
    let systemImage: String
    let line: BarSummary.Line?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Spacer()
            Text(line?.text ?? "No reports")
                .fontWeight(.semibold)
                .foregroundStyle(line == nil || line?.isGrayed == true ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.body)
        .accessibilityElement(children: .combine)
        .accessibilityValue(agedNote)
    }

    private var agedNote: String {
        line?.isGrayed == true ? "Older report" : ""
    }
}
