import Charts
import LineMapCore
import SwiftUI

/// History & details (FR-43): a bar's estimate right now in full, then any
/// night with reports as three stacked charts (line size, wait, crowd) from
/// 9 p.m. to 2 a.m. Dragging along them shows the values at that time.
/// Only combined estimates, never individual reports.
struct BarDetailsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bar: Bar
    /// The night asked for; nil is tonight.
    @State private var night: NightDate?
    @State private var history: BarHistory?
    @State private var loadFailed = false
    @State private var selectedTime: Date?

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
            .task(id: night) { await load() }
        }
        // Times are State College times, whatever the phone's time zone. Text
        // formats with the environment's zone, so set it here.
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

            if let history {
                nightControls(history)
                if history.hasData {
                    Readout(history: history, selectedTime: selectedTime)
                    HistoryCharts(history: history, selectedTime: $selectedTime)
                } else {
                    noData(history)
                }
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
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private func nightControls(_ history: BarHistory) -> some View {
        HStack {
            Menu {
                Picker("Night", selection: nightBinding(history)) {
                    ForEach(history.pickerNights, id: \.self) { date in
                        Text(date.label(tonight: history.tonight)).tag(date)
                    }
                }
            } label: {
                Label(history.night.label(tonight: history.tonight), systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Night: \(history.night.label(tonight: history.tonight))")
            .accessibilityIdentifier("night-picker")

            Spacer()

            Button("Same night last week") {
                night = history.night.adding(days: -7)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("same-night-last-week")
        }
    }

    private func nightBinding(_ history: BarHistory) -> Binding<NightDate> {
        Binding(get: { history.night },
                set: { night = $0 == history.tonight ? nil : $0 })
    }

    private func noData(_ history: BarHistory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(history.night == history.tonight ? "No reports tonight yet." : "No reports this night.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history-empty")
            if history.night == history.tonight {
                let lastWeek = history.night.adding(days: -7)
                Button("See last \(lastWeek.weekdayName)") {
                    night = lastWeek
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func load() async {
        loadFailed = false
        selectedTime = nil
        do {
            history = try await model.history(for: bar.id, night: night)
        } catch {
            // A newer night was picked; its own load takes over.
            if Task.isCancelled { return }
            history = nil
            loadFailed = true
        }
    }
}

/// The values at the dragged time, or the latest values when not dragging:
/// "11:35 PM · 25–50 in line · 32 min wait · Busy · 4 people".
private struct Readout: View {
    let history: BarHistory
    let selectedTime: Date?

    private var point: HistoryPoint? {
        if let selectedTime { return history.point(at: selectedTime) }
        return history.latestPointWithData
    }

    var body: some View {
        if let point {
            VStack(alignment: .leading, spacing: 4) {
                Text(point.at, format: Eastern.time)
                    .font(.headline)
                Text(values(point))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("history-readout")
        }
    }

    private func values(_ point: HistoryPoint) -> String {
        var parts: [String] = []
        if let text = point.lineSize.flatMap(Labels.historyLineSize) { parts.append(text) }
        if let text = point.wait.flatMap(Labels.historyWait) { parts.append(text) }
        if let text = point.busyness.flatMap(Labels.historyBusyness) { parts.append(text) }
        if parts.isEmpty { return "No reports within the hour" }
        parts.append(Labels.people(point.people))
        return parts.joined(separator: " · ")
    }
}

/// Line size, wait, and crowd, stacked on one time axis. One drag moves a
/// single cursor across all three.
private struct HistoryCharts: View {
    let history: BarHistory
    @Binding var selectedTime: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SignalChart(title: "Line size", levels: SignalChart.lineLevels, history: history,
                        value: \.lineSize, showsTimes: false, selectedTime: $selectedTime)
            SignalChart(title: "Wait", levels: SignalChart.waitLevels, history: history,
                        value: \.wait, showsTimes: false, selectedTime: $selectedTime)
            SignalChart(title: "Crowd", levels: SignalChart.crowdLevels, history: history,
                        value: \.busyness, showsTimes: true, selectedTime: $selectedTime)
            Text("Lighter bars are reports 30 to 60 minutes old.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// One signal through the night: a block at its level for each 5 minutes,
/// lighter when grayed out, empty when nothing is within 60 minutes.
private struct SignalChart: View {
    struct Level {
        let code: Int
        let label: String
    }

    static let lineLevels = [Level(code: 0, label: "0"), Level(code: 1, label: "1–10"),
                             Level(code: 2, label: "10–25"), Level(code: 3, label: "25–50"),
                             Level(code: 4, label: "50+")]
    static let waitLevels = [Level(code: 1, label: "<5m"), Level(code: 2, label: "5–15m"),
                             Level(code: 3, label: "15–30m"), Level(code: 4, label: "30–60m"),
                             Level(code: 5, label: "60m+")]
    static let crowdLevels = [Level(code: 1, label: "Quiet"), Level(code: 2, label: "Comfortable"),
                              Level(code: 3, label: "Busy"), Level(code: 4, label: "Packed")]

    let title: String
    let levels: [Level]
    let history: BarHistory
    let value: KeyPath<HistoryPoint, HistorySignal?>
    let showsTimes: Bool
    @Binding var selectedTime: Date?

    private var codes: ClosedRange<Double> {
        let all = levels.map(\.code)
        return Double(all.min() ?? 0) - 0.5 ... Double(all.max() ?? 4) + 0.5
    }

    private var hours: [Date] {
        let count = Int(history.end.timeIntervalSince(history.start) / 3600)
        return (0...max(count, 0)).map { history.start.addingTimeInterval(Double($0) * 3600) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Chart {
                ForEach(segments) { segment in
                    RectangleMark(
                        xStart: .value("Time", segment.start),
                        xEnd: .value("Time", segment.end),
                        yStart: .value("Level", Double(segment.code) - 0.35),
                        yEnd: .value("Level", Double(segment.code) + 0.35))
                        .foregroundStyle(Color.accentColor.opacity(segment.isStale ? 0.35 : 1))
                        .accessibilityLabel(
                            "\(segment.start.formatted(Eastern.time)) to \(segment.end.formatted(Eastern.time))")
                        .accessibilityValue(label(for: segment.code) + (segment.isStale ? ", older reports" : ""))
                }
                if let selectedTime {
                    RuleMark(x: .value("Selected", selectedTime))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: history.start ... history.end)
            .chartYScale(domain: codes)
            .chartXAxis {
                AxisMarks(values: hours) { value in
                    AxisGridLine()
                    if showsTimes, let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date, format: Eastern.hour)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: levels.map { Double($0.code) }) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let code = value.as(Double.self) {
                            // One width for every chart, so the three plots line up
                            // and the drag cursor sits at the same time in each.
                            Text(label(for: Int(code)))
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(width: 64, alignment: .leading)
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedTime)
            .frame(height: 140)
            .accessibilityLabel(title)
        }
    }

    private func label(for code: Int) -> String {
        levels.first { $0.code == code }?.label ?? ""
    }

    /// A stretch of the night with one value and one freshness.
    private struct Segment: Identifiable {
        let start: Date
        var end: Date
        let code: Int
        let isStale: Bool

        var id: Date { start }
    }

    /// Back-to-back 5-minute points with the same value become one block, so
    /// the chart has no seams and VoiceOver reads one span per stretch.
    private var segments: [Segment] {
        var result: [Segment] = []
        for point in history.points {
            guard let signal = point[keyPath: value] else { continue }
            let isStale = signal.freshness == .stale
            let end = min(point.at.addingTimeInterval(300), history.end)
            if let last = result.last, last.end == point.at, last.code == signal.code, last.isStale == isStale {
                result[result.count - 1].end = end
            } else {
                result.append(Segment(start: point.at, end: end, code: signal.code, isStale: isStale))
            }
        }
        return result
    }
}

/// Times in State College, whatever the phone's time zone (PRD 7.1).
enum Eastern {
    static let zone = TimeZone(identifier: "America/New_York") ?? .current

    /// "11:35 PM"
    static var time: Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return style
    }

    /// "9 PM"
    static var hour: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = zone
        return style
    }
}
