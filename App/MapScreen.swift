import LineMapCore
import MapKit
import SwiftUI

/// The Map tab (FR-1): an Apple Map of downtown with a pin per bar. A pin
/// opens the bar's sheet (presented by `RootView`).
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .region(Downtown.region)
    @State private var hasFramedBars = false
    /// The pin MapKit selected. Pins have no buttons of their own, so a pinch or
    /// pan that starts on a pin or label still moves the map (2026-10-04).
    @State private var selectedBarId: Int64?

    var body: some View {
        Map(position: $position, selection: $selectedBarId) {
            // The location dot only when permission was already granted (FR-1, FR-24).
            if model.location.isAuthorized {
                UserAnnotation()
            }
            ForEach(model.bars) { bar in
                Annotation(bar.name, coordinate: bar.coordinate, anchor: .bottom) {
                    BarPin(bar: bar, estimate: model.estimate(for: bar.id)) {
                        model.sheet = .bar(bar.id)
                    }
                }
                .annotationTitles(.hidden)
                .tag(bar.id)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay(alignment: .top) {
            if model.lastRefreshFailed {
                OfflineBanner(hasData: !model.bars.isEmpty)
            } else if !model.isLoaded && model.bars.isEmpty {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 8)
            }
        }
        .modifier(ReportingInset())
        .onAppear {
            frameBars()
            focusRequestedBar()
        }
        .onChange(of: model.bars) {
            frameBars()
        }
        // A tap on a pin opens its sheet, then clears the selection so the
        // same pin can be tapped again.
        .onChange(of: selectedBarId) { _, id in
            guard let id else { return }
            model.sheet = .bar(id)
            selectedBarId = nil
        }
        .onChange(of: model.mapFocus) {
            focusRequestedBar()
        }
    }

    /// Frames every bar once they first load (FR-1).
    private func frameBars() {
        guard !hasFramedBars, !model.bars.isEmpty else { return }
        hasFramedBars = true
        position = .region(Downtown.region(framing: model.bars))
    }

    /// Moves to the bar a Bars-list card asked for (FR-45), with the pin in the
    /// upper part of the map so the bar sheet doesn't cover it.
    private func focusRequestedBar() {
        guard let id = model.mapFocus, let bar = model.bar(id) else { return }
        model.mapFocus = nil
        hasFramedBars = true
        withAnimation {
            position = .region(Downtown.region(focusing: bar))
        }
    }
}

/// Downtown State College.
enum Downtown {
    static let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7942, longitude: -77.8612),
        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))

    /// A close-up of one bar, shifted so the pin sits above a bar sheet.
    static func region(focusing bar: Bar) -> MKCoordinateRegion {
        let span = 0.007
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: bar.doorLat - span * 0.3, longitude: bar.doorLon),
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    /// A region showing every bar with room for the pin labels.
    static func region(framing bars: [Bar]) -> MKCoordinateRegion {
        let lats = bars.map(\.doorLat)
        let lons = bars.map(\.doorLon)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return region }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.006, (maxLat - minLat) * 2.2),
                                   longitudeDelta: max(0.006, (maxLon - minLon) * 2.2)))
    }
}

extension Bar {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: doorLat, longitude: doorLon)
    }
}

/// A bar's pin with its label, e.g. "The Phyrst · 25 min" (FR-2).
struct BarPin: View {
    let bar: Bar
    let estimate: BarEstimate?
    /// For VoiceOver only. Taps go through the map's own selection.
    let action: () -> Void

    private var label: PinLabel { PinLabel(estimate: estimate) }

    /// Green, orange, or red by the line or wait the label shows, outlined for
    /// older reports; a gray pin for no data, closed, and outside hours.
    private var status: LineStatus? { LineStatus(estimate: estimate) }

    /// Filled for fresh reports; an outlined ring on white for older ones.
    @ViewBuilder
    private var pinImage: some View {
        if let status, status.isOlder {
            Image(systemName: status.level.outlineSystemImage)
                .font(.title)
                .foregroundStyle(status.level.color)
                .background(Circle().fill(.white).padding(2))
        } else {
            Image(systemName: status?.level.systemImage ?? "mappin.circle.fill")
                .font(.title)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, status?.level.color ?? Color.gray)
        }
    }

    var body: some View {
        // No Button: a button would keep any finger that lands on it, so a
        // pinch starting on a label couldn't zoom. MapKit selection handles taps.
        VStack(spacing: 2) {
            Text(label.title(barName: bar.name))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(label.isGrayed ? .secondary : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.quaternary))
            pinImage
        }
        .contentShape(.rect)
        // Labels stop growing at a size where neighbouring pins stay readable.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.title(barName: bar.name))
        .accessibilityValue(status?.level.title ?? "")
        .accessibilityHint(label.isGrayed ? "Older reports. Shows the line and crowd." : "Shows the line and crowd.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier("pin-\(bar.id)")
    }
}

/// Shown when the latest refresh failed.
struct OfflineBanner: View {
    let hasData: Bool

    var body: some View {
        Label(hasData ? "Offline. Showing the last update." : "Can't reach LineMap right now.",
              systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            .padding(.top, 8)
            .accessibilityIdentifier("offline-banner")
    }
}

/// Shows `AppModel.alert` from whichever view is on top, so alerts work while a
/// sheet is open.
struct AlertPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let isTopmost: Bool

    func body(content: Content) -> some View {
        content.alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { isTopmost && model.alert != nil },
                set: { if !$0 { model.dismissAlert() } }),
            presenting: model.alert
        ) { _ in
            Button("OK") { model.dismissAlert() }
        } message: { alert in
            Text(alert.message)
        }
    }
}
