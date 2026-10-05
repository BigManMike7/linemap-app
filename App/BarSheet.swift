import LineMapCore
import SwiftUI

/// A bar's line, wait, crowd, and freshness, with Start line timer and Report
/// conditions (FR-3). While in line here, Report conditions becomes I'm in.
/// History & details opens from the Bars list instead (FR-43, FR-45).
struct BarSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let bar: Bar
    @State private var confirmsNewLine = false
    @State private var confirmsLooksWrong = false

    private var isInLineHere: Bool { model.activeWait?.barId == bar.id }
    private var isInLineElsewhere: Bool { model.activeWait != nil && !isInLineHere }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            TimelineView(.periodic(from: .now, by: 30)) { context in
                summary(BarSummary(estimate: model.estimate(for: bar.id), now: context.date))
            }
            actions
        }
        .padding(20)
        .sheetFitsContent()
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
        // Directions goes under the name at the largest text sizes, so neither wraps.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
        return layout {
            // Name only; the address stays in the data for door pins (Max, 2026-10-04).
            Text(bar.name)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button {
                bar.openDirections()
            } label: {
                Label("Directions", systemImage: "figure.walk")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityHint("Opens walking directions in Apple Maps")
            .accessibilityIdentifier("directions-button")
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
            // A question with a confirmation, so a stray tap sends nothing (FR-35).
            Button("Does this look wrong?") {
                confirmsLooksWrong = true
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("looks-wrong-button")
            .confirmationDialog(
                "Does \(bar.name) look wrong?",
                isPresented: $confirmsLooksWrong,
                titleVisibility: .visible
            ) {
                Button("Yes, it looks wrong") { model.sendFeedback(for: bar) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This tells us the line or wait shown may be off. It doesn't change what anyone sees.")
            }
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
                    Text("Start line timer").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Starts a timer for your wait")
                .accessibilityIdentifier("in-line-button")
            }
            if isInLineHere {
                Button {
                    model.imIn()
                } label: {
                    Text("I'm in").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Stops your timer")
                .accessibilityIdentifier("bar-im-in-button")
            } else {
                Button {
                    model.askConditions(at: bar)
                } label: {
                    Text("Report conditions").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Share the line size and how busy it is")
                .accessibilityIdentifier("conditions-button")
            }
        }
        .controlSize(.large)
    }
}

/// One line of the bar sheet: an icon, a title, and a value that grays out when older.
/// At the largest text sizes the value goes under the title instead of beside it.
struct InfoRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let systemImage: String
    let line: BarSummary.Line?

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            if !stacked {
                Spacer()
            }
            Text(line?.text ?? "No reports")
                .fontWeight(.semibold)
                .foregroundStyle(line == nil || line?.isGrayed == true ? .secondary : .primary)
                .multilineTextAlignment(stacked ? .leading : .trailing)
        }
        .font(.body)
        .accessibilityElement(children: .combine)
        .accessibilityValue(agedNote)
    }

    private var agedNote: String {
        line?.isGrayed == true ? "Older report" : ""
    }
}
