import CoreLocation
import LineMapCore
import Observation

/// One location fix per report (FR-25). Permission is asked only on the first
/// report, never on launch (FR-24), and a missing or slow fix never blocks a
/// report: the offline queue sends it without one after a deadline (FR-27).
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Allowed, but with Precise Location turned off.
    private(set) var isApproximate = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let isEnabled: Bool
    @ObservationIgnored private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var fixWaiters: [CheckedContinuation<Reading?, Never>] = []

    /// The map shows the user's dot only when permission was already granted (FR-1).
    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Whether the next report will show the permission prompt.
    var needsPermission: Bool { isEnabled && authorization == .notDetermined }

    init(enabled: Bool) {
        isEnabled = enabled
        super.init()
        guard enabled else {
            authorization = .denied
            return
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorization = manager.authorizationStatus
        isApproximate = manager.accuracyAuthorization == .reducedAccuracy
    }

    /// Shows Apple's permission prompt if the person hasn't been asked yet. Only
    /// from Settings' Location row, which they tap themselves (FR-24).
    func requestPermission() {
        guard needsPermission else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// The current location for a report: precise, approximate, denied, or no fix.
    func currentFix(timeout: Duration = .seconds(10)) async -> LocationFix {
        guard isEnabled else { return .denied }
        await requestPermissionIfNeeded()
        guard isAuthorized else {
            return authorization == .notDetermined ? .noFix : .denied
        }

        let isApproximate = manager.accuracyAuthorization == .reducedAccuracy
        let reading = await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            if fixWaiters.count == 1 {
                manager.requestLocation()
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.finishFix(nil)
            }
        }
        guard let reading else { return .noFix }
        return LocationFix(
            status: isApproximate ? .approximate : .precise,
            latitude: reading.latitude,
            longitude: reading.longitude,
            accuracyMeters: reading.accuracy,
            ageSeconds: max(0, Date().timeIntervalSince(reading.timestamp))
        )
    }

    private func requestPermissionIfNeeded() async {
        guard authorization == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            if authorizationWaiters.count == 1 {
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        isApproximate = manager.accuracyAuthorization == .reducedAccuracy
        guard status != .notDetermined else { return }
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishFix(_ reading: Reading?) {
        let waiters = fixWaiters
        fixWaiters.removeAll()
        waiters.forEach { $0.resume(returning: reading) }
    }

    // MARK: - CLLocationManagerDelegate
    // CoreLocation calls these on the main thread, where the manager was created.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let reading = locations.last.map(Reading.init)
        MainActor.assumeIsolated { self.finishFix(reading) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { self.finishFix(nil) }
    }
}

/// The parts of a CLLocation a report needs, as plain values.
private struct Reading: Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let timestamp: Date

    nonisolated init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        timestamp = location.timestamp
    }
}
