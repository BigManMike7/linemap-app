import SwiftUI

@main
struct LineMapApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environment(model)
        }
    }
}
