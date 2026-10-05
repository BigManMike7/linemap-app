import LineMapCore
import SwiftUI

/// The Bars tab (FR-45): one simple card per bar, fresh before grayed out,
/// shortest wait first. Tapping a card shows the bar on the map with its sheet;
/// each card's History & details button opens the bar's full page (FR-43).
struct BarsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var detailsBar: Bar?

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
                        } showDetails: {
                            detailsBar = bar
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
        .fullScreenCover(item: $detailsBar) { bar in
            BarDetailsScreen(bar: bar)
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
/// when older (FR-45). A colored pill and a strip down the left edge show how
/// hard it is to get in. The top of the card is one button that shows the bar
/// on the map; History & details sits under it as its own button (FR-43).
struct BarCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let bar: Bar
    let estimate: BarEstimate?
    let action: () -> Void
    let showDetails: () -> Void

    private var status: LineStatus? { LineStatus(estimate: estimate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    content(BarSummary(estimate: estimate, now: context.date))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows \(bar.name) on the map")
            .accessibilityIdentifier("bar-card-\(bar.id)")

            Button(action: showDetails) {
                Label("History & details", systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("History & details for \(bar.name)")
            .accessibilityIdentifier("details-button-\(bar.id)")
        }
        .cardStyle(stripe: status?.color)
    }

    private func content(_ summary: BarSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.name)
                    .font(.headline)
                Spacer(minLength: 8)
                if let status, !typeSize.isAccessibilitySize {
                    LineLevelBadge(status: status)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            // The pill gets its own line at the largest text sizes.
            if let status, typeSize.isAccessibilitySize {
                LineLevelBadge(status: status)
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
