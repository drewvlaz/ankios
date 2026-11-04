import AnkiKit
import SwiftUI

@main
struct AnkiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.scenePhaseChanged(to: .active)
            case .background: model.scenePhaseChanged(to: .background)
            default: model.scenePhaseChanged(to: .inactive)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("skippedLogin") private var skippedLogin = false

    var body: some View {
        switch model.phase {
        case .starting:
            ProgressView("Opening collection…")
        case let .failed(message):
            ContentUnavailableView(
                "Couldn't open your collection",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .ready:
            if model.credentials == nil && !skippedLogin {
                // First run: lead with login, since that's how existing decks arrive.
                LoginView(onSkip: { skippedLogin = true })
            } else {
                DeckListView()
            }
        }
    }
}
