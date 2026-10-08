import LineMapCore
import SwiftUI

/// History (FR-43), opened from a Bars-list card: a calendar of nights in a
/// card, with a dot under each night that has reports. The chosen night shows as one row per quarter hour of its day, 4 a.m.
/// to 4 a.m., each covering only the reports in that quarter hour, with a
/// dot colored by its line level. Only combined estimates, never individual
/// reports. (Right now was removed on 2026-10-05: the bar sheet and Bars card
/// already show it.)
struct BarDetailsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bar: Bar

    @State private var selectedNight: NightDate
    @State private var history: BarHistory?
    /// Nights with reports, from the last load, so the calendar's dots stay
    /// while another night loads.
    @State private var nightsWithData: Set<NightDate> = []
    @State private var loadFailed = false

    private let tonight: NightDate

    init(bar: Bar, now: Date = Date()) {
        self.bar = bar
        let tonight = NightDate(nightOf: now, timeZone: Eastern.zone)
        self.tonight = tonight
        _selectedNight = State(initialValue: tonight)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                historySection
                    .cardStyle()
                    .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
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

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)

            // Tonight back to one year ago, the retention limit (FR-33).
            HistoryCalendar(night: $selectedNight, earliest: tonight.adding(days: -365), latest: tonight,
                            nightsWithData: nightsWithData)

            // No heading for the night: the calendar above already shows it.
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
            let loaded = try await model.history(for: bar.id, night: night)
            history = loaded
            nightsWithData = Set(loaded.nights)
        } catch {
            // A newer date was picked; its own load takes over.
            if Task.isCancelled { return }
            loadFailed = true
        }
    }
}

/// One night as a "Busiest around" line and a row per quarter hour (FR-43).
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
                let rows = history.rows
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .point(let point):
                            QuarterHourRow(point: point)
                        case .noReports(let from, let to):
                            NoReportsRow(from: from, to: to)
                        }
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } else {
            Text(history.night == history.tonight ? "No reports today yet." : "No reports this day.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history-empty")
        }
    }
}

/// "● 10:30 PM   25–50 in line · 30–60 min wait", with the number of
/// people under it. The dot is the line level's color. Stacks at the largest
/// text sizes. Rows built from reports 30–60 minutes old look like any other:
/// everything in History is in the past (Max's call, 2026-10-06).
private struct QuarterHourRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let point: HistoryPoint

    private var status: LineStatus? { LineStatus(point: point) }

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            HStack(spacing: 10) {
                LineLevelDot(status: status)
                Text(point.at, format: Eastern.time)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .frame(minWidth: typeSize.isAccessibilitySize ? nil : 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Labels.historyRow(point))
                    .foregroundStyle(point.hasData ? .primary : .secondary)
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
        .accessibilityValue(status?.level.title ?? "")
        .accessibilityIdentifier("history-row")
    }
}

/// "○ No reports, 3:15 PM – 8:45 PM": quarter hours in a row with nothing.
private struct NoReportsRow: View {
    let from: Date
    let to: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LineLevelDot(status: nil)
            Text("No reports, \(from.formatted(Eastern.time)) – \(to.formatted(Eastern.time))")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-gap")
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
