import LineMapCore
import SwiftUI

/// Floats over the map while a wait session is open (FR-4): the running timer,
/// a big I'm in, then Line size and Adjust time. The ✕ stops the timer, either
/// as gave up (FR-9) or as a line started by mistake (FR-39). Tapping the timer
/// opens the bar's sheet.
struct WaitCard: View {
    @Environment(AppModel.self) private var model
    let wait: ActiveWait
    let bar: Bar
    @State private var confirmsStop = false

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
                    confirmsStop = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52, minHeight: 52)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop timer")
                .accessibilityHint("Choose whether you gave up or started it by mistake")
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

                secondaryButton("Directions", id: "wait-directions") {
                    bar.openDirections()
                }
                .accessibilityHint("Opens walking directions in Apple Maps")
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
        .confirmationDialog("Stop this timer?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("I gave up on the line") { model.gaveUp() }
            Button("Started it by mistake", role: .destructive) { model.cancelLine() }
            Button("Keep timer", role: .cancel) {}
        } message: {
            Text("If you started it by mistake, nothing from it is saved.")
        }
    }

    private func secondaryButton(_ title: String, id: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
