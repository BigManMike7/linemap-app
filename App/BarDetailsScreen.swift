import LineMapCore
import SwiftUI

/// History & details (FR-43), opened from a Bars-list card: a bar's estimate
/// right now in full, then a calendar of nights. The chosen night shows as one
/// row per half hour, 9:00 p.m. to 1:30 a.m. Only combined estimates, never
/// individual reports.
struct BarDetailsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bar: Bar

    /// The calendar's selection: noon Eastern on the chosen night's date.
    @State private var selectedDate: Date
    @State private var history: BarHistory?
    @State private var loadFailed = false

    private let tonight: NightDate

    init(bar: Bar, now: Date = Date()) {
        self.bar = bar
        let tonight = NightDate(nightOf: now, timeZone: Eastern.zone)
        self.tonight = tonight
        _selectedDate = State(initialValue: tonight.noon(in: Eastern.zone))
    }

    private var selectedNight: NightDate {
        NightDate(calendarDateOf: selectedDate, timeZone: Eastern.zone)
    }

    /// Tonight back to one year ago, the retention limit (FR-33).
    private var selectableDates: ClosedRange<Date> {
        tonight.adding(days: -365).noon(in: Eastern.zone) ... tonight.noon(in: Eastern.zone)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    nowSection
                    historySection
                }
                .padding(20)
            }
            .navigationTitle(bar.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("details-close")
                }
            }
            .task(id: selectedNight) { await load() }
        }
        // Dates and times are State College's, whatever the phone's time zone.
        // The calendar and Text formatting both read the environment's zone.
        .environment(\.timeZone, Eastern.zone)
        .accessibilityIdentifier("bar-details")
    }

    // MARK: - Right now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Right now")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let summary = BarSummary(estimate: model.estimate(for: bar.id), now: context.date)
                VStack(alignment: .leading, spacing: 12) {
                    if let status = summary.status {
                        Text(status)
                            .foregroundStyle(.secondary)
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
                }
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)

            DatePicker("Night", selection: $selectedDate, in: selectableDates, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("history-calendar")

            Text(selectedNight == tonight ? "Tonight" : selectedNight.nightTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("history-night")

            if let history, history.night == selectedNight {
                NightRows(history: history)
            } else if loadFailed {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Couldn't load history. Check your connection.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    private func load() async {
        loadFailed = false
        let night = selectedNight
        do {
            history = try await model.history(for: bar.id, night: night)
        } catch {
            // A newer date was picked; its own load takes over.
            if Task.isCancelled { return }
            loadFailed = true
        }
    }
}

/// One night as a "Busiest around" line and a row per half hour (FR-43).
private struct NightRows: View {
    let history: BarHistory

    var body: some View {
        if history.hasData {
            VStack(alignment: .leading, spacing: 14) {
                if let busiest = history.busiestRow {
                    Label("Busiest around \(busiest.at.formatted(Eastern.time))", systemImage: "flame")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("history-busiest")
                }
                VStack(spacing: 0) {
                    ForEach(history.halfHourRows) { row in
                        HalfHourRow(point: row)
                        if row.id != history.halfHourRows.last?.id {
                            Divider()
                        }
                    }
                }
                Text("Grayed rows are reports 30 to 60 minutes old.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(history.night == history.tonight ? "No reports tonight yet." : "No reports this night.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history-empty")
        }
    }
}

/// "10:30 PM   25–50 in line · 30–60 min wait · Busy", with the number of
/// people under it. Stacks at the largest text sizes.
private struct HalfHourRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let point: HistoryPoint

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            Text(point.at, format: Eastern.time)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: typeSize.isAccessibilitySize ? nil : 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Labels.historyRow(point))
                    .foregroundStyle(point.hasData && !point.isGrayed ? .primary : .secondary)
                if point.hasData {
                    Text(Labels.people(point.people))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityValue(point.isGrayed ? "Older reports" : "")
        .accessibilityIdentifier("history-row")
    }
}

/// Times in State College, whatever the phone's time zone (PRD 7.1).
enum Eastern {
    static let zone = TimeZone(identifier: "America/New_York") ?? .current

    /// "11:30 PM"
    static var time: Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return style
    }
}
