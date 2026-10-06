import LineMapCore
import UIKit
import SwiftUI

/// The Settings tab (FR-5, FR-44): Made a wrong report? (FR-41), Delete my
/// data, the privacy policy and support pages, and the contact email.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsDelete = false
    /// Shows "Copied" on the Copy ID button for a moment.
    @State private var copiedID = false

    private let version = AppVersion(infoDictionary: Bundle.main.infoDictionary).label

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Made a wrong report?") {
                        RecentReportsView()
                    }
                    .accessibilityIdentifier("recent-reports-link")
                } footer: {
                    Text("Delete a report you made in the last 24 hours.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        HStack {
                            Text("Delete my data")
                            if model.isDeleting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isDeleting)
                    .accessibilityIdentifier("delete-data-button")
                } footer: {
                    Text("Deletes your reports, timers, and app activity from LineMap, then gives this phone a new anonymous ID. LineMap has no accounts and never stores your exact location.")
                }

                Section("About") {
                    Link("Privacy policy", destination: AppConfig.privacyURL)
                    Link("Support", destination: AppConfig.supportURL)
                    if let mail = URL(string: "mailto:\(AppConfig.contactEmail)") {
                        Link(AppConfig.contactEmail, destination: mail)
                    }
                    LabeledContent("Version", value: version)
                }

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
                        Text("A random ID that isn't linked to you. Support may ask for it.")
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete your data?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await model.deleteMyData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes everything LineMap has from this phone. It can't be undone.")
            }
        }
        .accessibilityIdentifier("settings")
    }
}
