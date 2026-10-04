import LineMapCore
import MapKit

extension Bar {
    /// Opens Apple Maps with walking directions to the door pin (FR-40). Needs
    /// no location permission: Maps asks for its own.
    func openDirections() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
