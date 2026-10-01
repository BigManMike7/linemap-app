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

    var body: some View {
        @Bindable var model = model
        Map(position: $position) {
            // The location dot only when permission was already granted (FR-1, FR-24).
            if model.location.isAuthorized {
                UserAnnotation()
            }
            ForEach(model.bars) { bar in
                Annotation(bar.name, coordinate: bar.coordinate, anchor: .bottom) {
                    BarPin(bar: bar, label: PinLabel(estimate: model.estimate(for: bar.id))) {
                        model.sheet = .bar(bar.id)
                    }
                }
                .annotationTitles(.hidden)
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
            if let wait = model.activeWait, let bar = model.activeWaitBar {
                WaitCard(wait: wait, bar: bar)
            }
        }
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
                BarSheet(bar: bar)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        case .question(let question):
            QuestionSheet(question: question)
                .presentationDetents([.large])
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
    let label: PinLabel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
                    .foregroundStyle(.white, label.isGrayed ? Color.gray : Color.accentColor)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.title(barName: bar.name))
        .accessibilityHint(label.isGrayed ? "Older reports. Shows the line and crowd." : "Shows the line and crowd.")
        .accessibilityAddTraits(.isButton)
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
