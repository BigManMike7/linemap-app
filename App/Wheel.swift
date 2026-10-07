import SwiftUI
import UIKit

/// Apple's wheel (UIPickerView) for picking one value, as in Line size and
/// Adjust time. It looks, ticks, and reads to VoiceOver like SwiftUI's wheel
/// Picker, but it also says whether it is still moving: the wheel picks a value
/// only once it stops, so Save stays gray until then.
struct Wheel<Value: Hashable>: UIViewRepresentable {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let motion: WheelMotion
    let id: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = WatchedPicker()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.accessibilityIdentifier = id
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let row = options.firstIndex(of: selection) {
            picker.selectRow(row, inComponent: 0, animated: false)
        }
        // The wheel's scroll views exist once it is laid out.
        picker.onLayout = { [motion] picker in motion.watch(picker) }
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.wheel = self
        // Follow the selection only when it changed from outside, never mid-spin.
        if let row = options.firstIndex(of: selection), row != picker.selectedRow(inComponent: 0),
           !motion.isMoving {
            picker.selectRow(row, inComponent: 0, animated: false)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPickerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: 216)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate,
                             UIPickerViewAccessibilityDelegate {
        var wheel: Wheel

        init(_ wheel: Wheel) {
            self.wheel = wheel
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            wheel.options.count
        }

        // Rows grow with the text size, like SwiftUI's wheel.
        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
            ceil(UIFont.preferredFont(forTextStyle: .title3).lineHeight) + 12
        }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int,
                        reusing view: UIView?) -> UIView {
            let label = view as? UILabel ?? UILabel()
            label.font = .preferredFont(forTextStyle: .title3)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.text = wheel.title(wheel.options[row])
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            wheel.selection = wheel.options[row]
        }

        func pickerView(_ pickerView: UIPickerView, accessibilityLabelForComponent component: Int) -> String? {
            wheel.label
        }
    }
}

/// Tells the wheel's motion watcher when its insides have been laid out.
private final class WatchedPicker: UIPickerView {
    var onLayout: ((UIPickerView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

/// Whether a wheel is moving: a finger on it, coasting, or settling onto a row.
/// The wheel's insides aren't documented by Apple, so a future iOS could hide
/// them; then `isMoving` stays false and `isMovingNow` is nil, and callers fall
/// back to a safer rule.
@Observable
final class WheelMotion {
    /// For the Save button: true from the first movement until the wheel has
    /// been still for a moment.
    private(set) var isMoving = false

    @ObservationIgnored private weak var picker: UIPickerView?
    @ObservationIgnored private var offsetWatches: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastOffsetChange: CFTimeInterval = 0

    /// Whether the wheel is moving right now, or nil if the app can't tell.
    var isMovingNow: Bool? {
        guard let picker else { return nil }
        let scrollViews = Self.scrollViews(in: picker)
        guard !scrollViews.isEmpty else { return nil }
        return isMoving || scrollViews.contains { $0.isTracking || $0.isDragging || $0.isDecelerating }
    }

    fileprivate func watch(_ picker: UIPickerView) {
        self.picker = picker
        guard offsetWatches.isEmpty else { return }
        offsetWatches = Self.scrollViews(in: picker).map { scrollView in
            scrollView.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.offsetChanged() }
            }
        }
    }

    /// Any scroll: a finger, coasting, or the last settle onto a row. The wheel
    /// setting its own row (opening on the last answer) doesn't count.
    private func offsetChanged() {
        lastOffsetChange = CACurrentMediaTime()
        guard !isMoving, let picker,
              Self.scrollViews(in: picker).contains(where: { $0.isTracking || $0.isDragging || $0.isDecelerating })
        else { return }
        isMoving = true
        // Checks every frame until the wheel stops, then goes quiet.
        // If the sheet closes mid-spin, the watcher is gone and the link stops.
        let link = CADisplayLink(target: FrameTarget { [weak self] in self?.frame() ?? false },
                                 selector: #selector(FrameTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
    }

    /// Stopped: no finger, no coasting, and no settling for a moment. Returns
    /// whether to keep checking.
    private func frame() -> Bool {
        if let picker {
            let busy = Self.scrollViews(in: picker).contains { $0.isTracking || $0.isDragging || $0.isDecelerating }
            if busy || CACurrentMediaTime() - lastOffsetChange <= 0.15 {
                return true
            }
        }
        isMoving = false
        return false
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        view.subviews.flatMap { subview -> [UIScrollView] in
            if let scrollView = subview as? UIScrollView {
                [scrollView]
            } else {
                scrollViews(in: subview)
            }
        }
    }
}

/// A display link holds its target strongly, so it calls this instead of the
/// watcher, which can then go away with its sheet. The action returns whether
/// to keep going.
private final class FrameTarget: NSObject {
    let action: () -> Bool

    init(_ action: @escaping () -> Bool) {
        self.action = action
    }

    @objc func fire(_ link: CADisplayLink) {
        if !action() {
            link.invalidate()
        }
    }
}
