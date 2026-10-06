import SwiftUI

/// The three tabs (FR-44): Map, Bars, and Settings. Sheets and alerts hang off
/// the tab view, so a bar sheet or a question opens the same way from any tab.
///
/// After a full close the app opens on Map, since `AppModel.tab` starts there.
/// Going to the home screen and back keeps the tab and screen (the iOS default).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            MapScreen()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(AppTab.map)
            BarsScreen()
                .tabItem { Label("Bars", systemImage: "list.bullet") }
                .tag(AppTab.bars)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(AppConfig.uiTestColorScheme)
        .sensoryFeedback(trigger: model.thanks) { _, new in
            guard let new else { return nil }
            return new.text == Thanks.noChange ? .warning : .success
        }
        .sensoryFeedback(.success, trigger: model.adjustTimeSaves)
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
                .presentationDragIndicator(.visible)
                .modifier(AlertPresenter(isTopmost: true))
        }
        .modifier(AlertPresenter(isTopmost: model.sheet == nil))
        .task {
            await model.start()
            // Keep estimates current while the app is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.becameActive() }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .bar(let id):
            if let bar = model.bar(id) {
                // Both size themselves to their content (sheetFitsContent).
                BarSheet(bar: bar)
            }
        case .question(let question):
            QuestionSheet(question: question)
        }
    }
}

/// The thank-you and the wait card, just above the tab bar on the Map and Bars
/// tabs (FR-4, FR-42). Settings leaves them out; the timer keeps running.
struct ReportingInset: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let thanks = model.thanks {
                    ThanksMessage(thanks: thanks)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let wait = model.activeWait, let bar = model.activeWaitBar {
                    WaitCard(wait: wait, bar: bar)
                }
            }
            .padding(.bottom, 8)
            .animation(.snappy, value: model.thanks)
        }
    }
}

/// The short message after a report (FR-42). It goes away on its own. After
/// I'm in or Gave up it has Undo, which brings the timer back (FR-47).
struct ThanksMessage: View {
    @Environment(AppModel.self) private var model
    let thanks: Thanks

    var body: some View {
        HStack(spacing: 12) {
            Label(thanks.text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .accessibilityIdentifier("thanks-message")
            // No Undo once another timer has started.
            if thanks.undo != nil && model.activeWait == nil {
                Spacer(minLength: 0)
                Button("Undo") { model.undoStop() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .padding(.vertical, -8)
                    .accessibilityHint("Brings your timer back")
                    .accessibilityIdentifier("thanks-undo")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }
}
