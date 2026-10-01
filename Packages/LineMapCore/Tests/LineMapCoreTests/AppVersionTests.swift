import LineMapCore
import Testing

struct AppVersionTests {
    @Test func `label shows the marketing version and build`() {
        #expect(AppVersion(marketing: "0.1.0", build: "12").label == "0.1.0 (12)")
    }

    @Test func `reads both values from Info.plist keys`() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"]
        #expect(AppVersion(infoDictionary: info) == AppVersion(marketing: "1.2.3", build: "45"))
    }

    @Test func `missing keys show a question mark`() {
        #expect(AppVersion(infoDictionary: nil).label == "? (?)")
        #expect(AppVersion(infoDictionary: ["CFBundleVersion": 7]).label == "? (?)")
    }
}
