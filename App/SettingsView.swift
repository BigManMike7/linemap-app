import LineMapCore
import SwiftUI

/// Settings (FR-5): Delete my data, the privacy policy and support pages, and the contact email.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    private let version = AppVersion(infoDictionary: Bundle.main.infoDictionary).label

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
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
