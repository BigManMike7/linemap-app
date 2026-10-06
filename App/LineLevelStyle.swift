import LineMapCore
import SwiftUI

/// Colors and symbols for how hard a bar is to get into (FR-2, FR-43, FR-45):
/// green, orange, and red, each with its own symbol so color is never the only
/// signal, and a gray question mark when the wait and line size contradict. Reports 30–60 minutes old show faded or outlined.
extension LineLevel {
    var color: Color {
        switch self {
        case .short: .green
        case .some: .orange
        case .long: .red
        case .uncertain: .gray
        }
    }

    var systemImage: String {
        switch self {
        case .short: "checkmark.circle.fill"
        case .some: "clock.circle.fill"
        case .long: "exclamationmark.circle.fill"
        case .uncertain: "questionmark.circle.fill"
        }
    }

    /// The same symbol unfilled, for pins from older reports.
    var outlineSystemImage: String {
        switch self {
        case .short: "checkmark.circle"
        case .some: "clock.circle"
        case .long: "exclamationmark.circle"
        case .uncertain: "questionmark.circle"
        }
    }
}

extension LineStatus {
    /// The level's color, faded for older reports.
    var color: Color {
        level.color.opacity(isOlder ? 0.45 : 1)
    }
}

/// A pill such as "✓ Short line", on Bars cards and the bar sheet.
struct LineLevelBadge: View {
    let status: LineStatus

    var body: some View {
        Label {
            Text(status.level.title)
                .foregroundStyle(status.isOlder ? .secondary : .primary)
        } icon: {
            Image(systemName: status.level.systemImage)
                .foregroundStyle(status.color)
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(status.level.color.opacity(status.isOlder ? 0.08 : 0.16), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spokenText)
        .accessibilityIdentifier("line-level")
    }
}

/// A dot for one quarter hour of History (FR-43): the level's color, or an empty
/// ring when nothing was reported.
struct LineLevelDot: View {
    let status: LineStatus?

    var body: some View {
        Group {
            if let status {
                // Full color even for older reports: History is all past (FR-43).
                Circle().fill(status.level.color)
            } else {
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

/// A rounded card on the grouped background, as on the Bars tab and History &
/// details. An optional colored strip runs down its left edge.
struct CardStyle: ViewModifier {
    var stripe: Color?

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(alignment: .leading) {
                if let stripe {
                    stripe
                        .frame(width: 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(.rect(cornerRadius: 16))
    }
}

extension View {
    func cardStyle(stripe: Color? = nil) -> some View {
        modifier(CardStyle(stripe: stripe))
    }
}
