import LineMapCore
import SwiftUI

/// Floats over the map while a wait session is open (FR-4): the running timer,
/// I'm in, Gave up, and a line-size update. Tapping it opens the bar's sheet.
struct WaitCard: View {
    @Environment(AppModel.self) private var model
    let wait: ActiveWait
    let bar: Bar
    @State private var confirmsGiveUp = false
    @State private var confirmsCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button {
                    model.sheet = .bar(bar.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In line at \(bar.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(wait.timer.text(at: context.date))
                                .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(bar.name)")

                // Cancel (FR-39): for a line started by mistake.
                Button {
                    confirmsCancel = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel line")
                .accessibilityHint("Discards this timer. Nothing is saved.")
                .accessibilityIdentifier("wait-cancel")
            }

            HStack(spacing: 10) {
                Button {
                    model.askLineSizeUpdate()
                } label: {
                    Text("Line size").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Update line size")
                .accessibilityIdentifier("wait-update-line")

                Button {
                    model.imIn()
                } label: {
                    Text("I'm in").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wait-im-in")

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
        .confirmationDialog("Cancel this line?", isPresented: $confirmsCancel, titleVisibility: .visible) {
            Button("Cancel line", role: .destructive) { model.cancelLine() }
            Button("Keep timer", role: .cancel) {}
        } message: {
            Text("Use this if you started it by mistake. Nothing from it is saved.")
        }
    }
}
