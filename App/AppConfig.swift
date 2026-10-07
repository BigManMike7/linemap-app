import Foundation
import SwiftUI

/// Public settings. The Supabase URL and publishable key are public by design;
/// row-level security and the function grants protect the data.
enum AppConfig {
    static let supabaseURL = URL(string: "https://jjsccwmvgfzsxozhjlrt.supabase.co")!
    static let supabaseKey = "sb_publishable_fh1TMV_EqzGJxKLMLyyT2A_9s24K5Lz"

    static let privacyURL = URL(string: "https://bigmanmike7.github.io/linemap-app/privacy")!
    static let supportURL = URL(string: "https://bigmanmike7.github.io/linemap-app/support")!
    static let contactEmail = "line.map.support@gmail.com"

    /// Set by the screenshot UI test: canned data, no network, no location prompts.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    /// UI tests only (temporary, 2026-10-07): opens the map this many degrees of
    /// longitude across with the scale bar always showing, to find the zoom
    /// where Apple's scale turns from 0–100 ft to 0–75 ft.
    static var uiTestMapProbe: Double? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ui-map-probe"), index + 1 < arguments.count else { return nil }
        return Double(arguments[index + 1])
    }

    /// Light mode for the UI test's second walkthrough; otherwise nil, which
    /// follows the phone's setting.
    static var uiTestColorScheme: ColorScheme? {
        ProcessInfo.processInfo.arguments.contains("-ui-light") ? .light : nil
    }
}
