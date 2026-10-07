import Foundation

/// Save on the Line size wheel (FR-6). The wheel picks a size only once it
/// stops, so a Save mid-spin still shows the last answer. A different size
/// always sends. The same size again sends only 5 minutes or more after the
/// last one was sent (a fresh report); sooner, or before any answer (the wheel
/// opens on No line), it is No change and nothing is sent.
public enum LineSizeSave {
    public static let sameSizeAgainAfter: TimeInterval = 5 * 60

    public static func sends(_ size: LineSize, last: LineSize?, lastSentAt: Date?, now: Date) -> Bool {
        guard size == (last ?? .nobody) else { return true }
        guard let lastSentAt else { return false }
        return now.timeIntervalSince(lastSentAt) >= sameSizeAgainAfter
    }

    /// The thank-you names the size, so a Save that caught the wheel mid-spin is
    /// easy to spot (FR-42): "Thanks! 10–25 in line is now visible to everyone."
    public static func thanks(_ size: LineSize, online: Bool) -> String {
        let what = size == .nobody ? Labels.option(size) : "\(Labels.option(size)) in line"
        return online
            ? "Thanks! \(what) is now visible to everyone."
            : "Thanks! \(what) will send when you're back online."
    }
}
