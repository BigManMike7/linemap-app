import LineMapCore
import MapKit
import SwiftUI

/// The home screen (FR-1): an Apple Map of downtown with a pin per bar.
/// Everything else opens as a sheet over it.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var position: MapCameraPosition = .region(Downtown.region)
    @State private var hasFramedBars = false
    /// The pin MapKit selected. Pins have no buttons of their own, so a pinch or
    /// pan that starts on a pin or label still moves the map (2026-10-04).
    @State private var selectedBarId: Int64?

    var body: some View {
        @Bindable var model = model
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
        .overlay(alignment: .topTrailing) {
            settingsButton
        }
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let thanks = model.thanks {
                    ThanksMessage(text: thanks.text)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let wait = model.activeWait, let bar = model.activeWaitBar {
                    WaitCard(wait: wait, bar: bar)
                }
            }
            .animation(.snappy, value: model.thanks)
        }
        .sensoryFeedback(.success, trigger: model.thanks) { _, new in new != nil }
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
                .modifier(AlertPresenter(isTopmost: true))
        }
        .modifier(AlertPresenter(isTopmost: model.sheet == nil))
        .task {
            await model.start()
            frameBars()
            // Keep estimates current while the map is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await model.refresh()
            }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.becameActive() }
            }
        }
    }

    private var settingsButton: some View {
        Button {
            model.sheet = .settings
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settings-button")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .bar(let id):
            if let bar = model.bar(id) {
                // Both size themselves to their content (sheetFitsContent).
                BarSheet(bar: bar)
                    .presentationDragIndicator(.visible)
            }
        case .question(let question):
            QuestionSheet(question: question)
                .presentationDragIndicator(.visible)
        case .settings:
            SettingsView()
        }
    }

    /// Frames every bar once they first load (FR-1).
    private func frameBars() {
        guard !hasFramedBars, !model.bars.isEmpty else { return }
        hasFramedBars = true
        position = .region(Downtown.region(framing: model.bars))
    }
}

/// The short thank-you after a report is accepted (FR-42). It needs no action
/// and goes away on its own.
struct ThanksMessage: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("thanks-message")
    }
}

/// Downtown State College.
enum Downtown {
    static let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7942, longitude: -77.8612),
        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))

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

    /// Colored only when the pin shows a fresh line or wait; gray for older
    /// reports, no data, closed, and outside hours.
    private var isLive: Bool {
        guard let estimate, estimate.display == .estimate, !label.isGrayed else { return false }
        return estimate.wait != nil || estimate.lineSize != nil
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
            Image(systemName: "mappin.circle.fill")
                .font(.title)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isLive ? Color.accentColor : Color.gray)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.title(barName: bar.name))
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
