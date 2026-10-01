import LineMapCore
import SwiftUI

/// Floats over the map while a wait session is open (FR-4): the running timer,
/// a big I'm in, then Line size, Adjust time, and Gave up. The ✕ cancels a line
/// started by mistake (FR-39). Tapping the timer opens the bar's sheet.
struct WaitCard: View {
    @Environment(AppModel.self) private var model
    let wait: ActiveWait
    let bar: Bar
    @State private var confirmsGiveUp = false
    @State private var confirmsCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Button {
                model.imIn()
            } label: {
                Text("I'm in")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("wait-im-in")

            HStack(spacing: 8) {
                secondaryButton("Line size", id: "wait-update-line") {
                    model.askLineSize()
                }
                .accessibilityLabel("Report line size")

                secondaryButton("Adjust time", id: "wait-adjust-time") {
                    model.askAdjustTime()
                }
                .accessibilityHint("Starts your timer earlier if you were already in line")

                secondaryButton("Gave up", role: .destructive, id: "wait-gave-up") {
                    confirmsGiveUp = true
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
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
            Button("Discard line", role: .destructive) { model.cancelLine() }
            Button("Keep timer", role: .cancel) {}
        } message: {
            Text("Use this if you started it by mistake. Nothing from it is saved.")
        }
    }

    private func secondaryButton(_ title: String, role: ButtonRole? = nil, id: String,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }
}
