import LineMapCore
import SwiftUI

/// The Bars tab (FR-45): one simple card per bar, fresh before grayed out,
/// shortest wait first. Tapping a card shows the bar on the map with its sheet.
struct BarsScreen: View {
    @Environment(AppModel.self) private var model

    private var orderedBars: [Bar] {
        BarOrder.sorted(model.bars, estimates: model.estimates)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.lastRefreshFailed && !model.bars.isEmpty {
                        OfflineBanner(hasData: true)
                    }
                    ForEach(orderedBars) { bar in
                        BarCard(bar: bar, estimate: model.estimate(for: bar.id)) {
                            model.showOnMap(bar)
                        }
                    }
                }
                .padding(16)
                .animation(.snappy, value: orderedBars.map(\.id))
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay {
                if model.bars.isEmpty {
                    emptyState
                }
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Bars")
            .modifier(ReportingInset())
        }
        .accessibilityIdentifier("bars-screen")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.lastRefreshFailed {
            ContentUnavailableView {
                Label("Can't reach LineMap", systemImage: "wifi.slash")
            } description: {
                Text("Check your connection, then pull down to try again.")
            }
        } else {
            ProgressView()
        }
    }
}

/// One bar in the list: name, line, wait, crowd, and freshness, grayed out
/// when older (FR-45). The whole card is one button.
struct BarCard: View {
    let bar: Bar
    let estimate: BarEstimate?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(BarSummary(estimate: estimate, now: context.date))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows \(bar.name) on the map")
        .accessibilityIdentifier("bar-card-\(bar.id)")
    }

    private func content(_ summary: BarSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(bar.name)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
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
