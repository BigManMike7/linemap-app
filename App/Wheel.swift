import SwiftUI
import UIKit

/// Apple's wheel (UIPickerView) for picking one value, as in Line size and
/// Adjust time. It looks, ticks, and reads to VoiceOver like SwiftUI's wheel
/// Picker, but it can also say whether it is still moving: the wheel picks a
/// value only once it stops, so a Save tapped mid-spin would send the old one.
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
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.accessibilityIdentifier = id
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let row = options.firstIndex(of: selection) {
            picker.selectRow(row, inComponent: 0, animated: false)
        }
        motion.picker = picker
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.wheel = self
        // Follow the selection only when it changed from outside, never mid-spin.
        if let row = options.firstIndex(of: selection), row != picker.selectedRow(inComponent: 0),
           motion.isMoving != true {
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

/// Whether a wheel is still moving, checked when Save is tapped.
final class WheelMotion {
    fileprivate weak var picker: UIPickerView?

    /// True while a finger is on the wheel or it is still coasting. Nil when
    /// the app can't tell: the wheel's insides aren't documented by Apple, so a
    /// future iOS could hide them, and callers then fall back to a safer rule.
    var isMoving: Bool? {
        guard let picker else { return nil }
        let scrollViews = Self.scrollViews(in: picker)
        guard !scrollViews.isEmpty else { return nil }
        return scrollViews.contains { $0.isTracking || $0.isDragging || $0.isDecelerating }
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
