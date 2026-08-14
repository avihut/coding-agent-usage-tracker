import SwiftUI

/// The app's one segmented-picker look — bare, self-sized, semibold labels.
/// Every surface builds pickers through this so the style lives in exactly
/// one place; change it here and the panel and settings move together.
struct SegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    /// Panel surfaces run .mini; settings panes pass .regular.
    var size: ControlSize = .mini

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { option in
                Text(option.label).fontWeight(.semibold).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(size)
        .labelsHidden()
        .fixedSize()
    }
}
