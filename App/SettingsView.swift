import LineMapCore
import UIKit
import SwiftUI

/// The Settings tab (FR-5, FR-44): Time in lines (FR-48), Made a wrong report?
/// (FR-41), the privacy policy and support pages, the contact email, location
/// access (FR-24), and the anonymous ID, which people email to support to delete their data (FR-32).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Shows "Copied" on the Copy ID button for a moment.
    @State private var copiedID = false
    /// Pages open over Settings. Cleared on leaving the tab, so Settings
    /// always comes back on its main page (Max, 2026-10-08).
    @State private var path: [SettingsPage] = []

    private let version = AppVersion(infoDictionary: Bundle.main.infoDictionary).label

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                TimeInLinesSection()

                Section {
                    NavigationLink("Made a wrong report?", value: SettingsPage.recentReports)
                        .accessibilityIdentifier("recent-reports-link")
                } footer: {
                    Text("Delete a report you made in the last 24 hours.")
                }

                Section("About") {
                    Link("Privacy policy", destination: AppConfig.privacyURL)
                    Link("Support", destination: AppConfig.supportURL)
                    if let mail = URL(string: "mailto:\(AppConfig.contactEmail)") {
                        Link(AppConfig.contactEmail, destination: mail)
                    }
                    LabeledContent("Version", value: version)
                }

                LocationSection()

                if let anonId = model.anonId?.uuidString {
                    Section {
                        Text(anonId)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel("Anonymous ID")
                        Button {
                            UIPasteboard.general.string = anonId
                            copiedID = true
                            UIAccessibility.post(notification: .announcement, argument: "ID copied")
                        } label: {
                            if copiedID {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Text("Copy ID")
                            }
                        }
                        .sensoryFeedback(.success, trigger: copiedID) { _, copied in copied }
                        .task(id: copiedID) {
                            guard copiedID else { return }
                            try? await Task.sleep(for: .seconds(2))
                            copiedID = false
                        }
                        .accessibilityIdentifier("copy-id-button")
                    } header: {
                        Text("Anonymous ID")
                    } footer: {
                        Text("A random ID that isn't linked to you. Support may ask for it. To delete your data, email support with this ID.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .recentReports: RecentReportsView()
                }
            }
        }
        .onChange(of: model.tab) { _, tab in
            if tab != .settings { path.removeAll() }
        }
        .accessibilityIdentifier("settings")
    }
}

/// A page opened from Settings.
private enum SettingsPage: Hashable {
    case recentReports
}

/// Location access (FR-24, 2026-10-08). Before the person has been asked, a
/// tap shows Apple's prompt, since they chose to tap it; after that it opens
/// LineMap's page in the iPhone's Settings. A red note says when location
/// isn't allowed.
private struct LocationSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let location = model.location
        Section {
            Button {
                if location.needsPermission {
                    location.requestPermission()
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                LabeledContent("Location access", value: status(of: location))
            }
            .accessibilityIdentifier("location-settings")
        } header: {
            Text("Location")
        } footer: {
            if !location.isAuthorized {
                Text("Location isn't allowed. Allowing it helps keep reports accurate.")
                    .foregroundStyle(.red)
            }
        }
    }

    private func status(of location: LocationService) -> String {
        if location.isAuthorized {
            location.isApproximate ? "Approximate" : "Allowed"
        } else if location.authorization == .notDetermined {
            "Not allowed yet"
        } else {
            "Not allowed"
        }
    }
}

/// Time in lines (FR-48): the person's total from every timed wait that ended
/// with I'm in or Gave up, Adjust time included. It loads each time Settings
/// shows, so a wait just finished or deleted is counted right.
private struct TimeInLinesSection: View {
    @Environment(AppModel.self) private var model
    @State private var failed = false

    var body: some View {
        Section {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wait-stats")
                .task {
                    do {
                        try await model.refreshWaitStats()
                        failed = false
                    } catch {
                        failed = true
                    }
                }
        } header: {
            Text("Time in lines")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let stats = model.waitStats {
            if stats.waits == 0 {
                Label("No lines timed yet", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "hourglass")
                        .font(.title)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stats.totalLabel)
                            .font(.title.bold())
                        Text(stats.detailLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } else if failed {
            Text("Couldn't load your time. Check your connection.")
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}
