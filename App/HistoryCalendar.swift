import LineMapCore
import SwiftUI
import UIKit

/// History's calendar (FR-43): Apple's calendar (UICalendarView) with a dot in
/// the accent color under each night that has reports at the bar, so it's clear
/// where to tap. SwiftUI's graphical DatePicker is the same calendar but can't
/// mark dates; the dots are UICalendarView's own decorations. Dates are State
/// College's, whatever the phone's time zone.
struct HistoryCalendar: UIViewRepresentable {
    @Binding var night: NightDate
    /// The nights that can be picked: tonight back one year.
    let earliest: NightDate
    let latest: NightDate
    let nightsWithData: Set<NightDate>

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Self.calendar
        view.timeZone = Eastern.zone
        view.delegate = context.coordinator
        view.availableDateRange = DateInterval(
            start: Self.calendar.startOfDay(for: earliest.noon(in: Eastern.zone)),
            end: latest.noon(in: Eastern.zone).addingTimeInterval(11 * 3600))
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        selection.selectedDate = Self.components(night)
        view.selectionBehavior = selection
        view.visibleDateComponents = Self.components(night)
        view.accessibilityIdentifier = "history-calendar"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.decorated = nightsWithData
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Redraw only the dots that came or went.
        let changed = coordinator.decorated.symmetricDifference(nightsWithData)
        coordinator.decorated = nightsWithData
        if !changed.isEmpty {
            view.reloadDecorations(forDateComponents: changed.map(Self.components), animated: true)
        }
        if let selection = view.selectionBehavior as? UICalendarSelectionSingleDate,
           selection.selectedDate.flatMap(Self.night) != night {
            selection.setSelected(Self.components(night), animated: true)
        }
    }

    // A month can need five or six rows, and larger text makes it taller.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let height = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: HistoryCalendar
        /// The nights with a dot right now.
        var decorated: Set<NightDate> = []

        init(_ parent: HistoryCalendar) {
            self.parent = parent
        }

        func calendarView(_ calendarView: UICalendarView,
                          decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let night = HistoryCalendar.night(dateComponents), decorated.contains(night) else { return nil }
            return .default(color: UIColor(named: "AccentColor") ?? .tintColor, size: .medium)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let night = dateComponents.flatMap(HistoryCalendar.night) else { return }
            parent.night = night
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Eastern.zone
        return calendar
    }()

    private static func components(_ night: NightDate) -> DateComponents {
        DateComponents(calendar: calendar, timeZone: Eastern.zone,
                       year: night.year, month: night.month, day: night.day)
    }

    private static func night(_ components: DateComponents) -> NightDate? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return NightDate(year: year, month: month, day: day)
    }
}
