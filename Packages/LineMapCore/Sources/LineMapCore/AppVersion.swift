/// The app's version as people see it, e.g. "0.1.0 (12)".
///
/// Reports will record the app version too (NFR-10).
public struct AppVersion: Sendable, Equatable {
    public let marketing: String
    public let build: String

    public init(marketing: String, build: String) {
        self.marketing = marketing
        self.build = build
    }

    /// Reads the version from an Info.plist dictionary. Missing keys show as "?".
    public init(infoDictionary: [String: Any]?) {
        marketing = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    public var label: String { "\(marketing) (\(build))" }
}
