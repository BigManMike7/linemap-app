import LineMapCore
import SwiftUI

/// Floats over the map while a wait session is open (FR-4): the running timer,
/// I'm in, Gave up, and a line-size update. Tapping it opens the bar's sheet.
struct WaitCard: View {
    @Environment(AppModel.self) private var model
    let wait: ActiveWait
    let bar: Bar
    @State private var confirmsGiveUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.sheet = .bar(bar.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In line at \(bar.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(wait.timer.text(at: context.date))
                                .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(bar.name)")

            HStack(spacing: 10) {
                Button {
                    model.imIn()
                } label: {
                    Text("I'm in").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wait-im-in")

                Button {
                    model.askLineSizeUpdate()
                } label: {
                    Text("Line size").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Update line size")
                .accessibilityIdentifier("wait-update-line")

                Button(role: .destructive) {
                    confirmsGiveUp = true
                } label: {
                    Text("Gave up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("wait-gave-up")
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wait-card")
        .confirmationDialog("Stop your timer?", isPresented: $confirmsGiveUp, titleVisibility: .visible) {
            Button("Gave up", role: .destructive) { model.gaveUp() }
            Button("Keep waiting", role: .cancel) {}
        } message: {
            Text("Your wait won't be counted.")
        }
    }
}
