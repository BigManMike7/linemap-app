import LineMapCore
import SwiftUI

/// M1 placeholder. M3 replaces this with the map home screen (FR-1).
struct RootView: View {
    private let version = AppVersion(infoDictionary: Bundle.main.infoDictionary)

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("LineMap")
                .font(.largeTitle.bold())
            Text("Version \(version.label)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RootView()
}
