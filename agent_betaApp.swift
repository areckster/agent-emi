import SwiftUI

@main
struct AgentLuxApp: App {
    @StateObject private var prefs: AppPrefs
    @StateObject private var store: ChatStore
    @StateObject private var runner: LLMRunner

    init() {
        let prefsInstance = AppPrefs()
        _prefs = StateObject(wrappedValue: prefsInstance)
        let storeInstance = ChatStore()
        _store = StateObject(wrappedValue: storeInstance)
        let runnerInstance = LLMRunner()
        _runner = StateObject(wrappedValue: runnerInstance)
        AppEnv.prefs = prefsInstance
        AppEnv.store = storeInstance
    }

    var body: some Scene {
        WindowGroup {
            MimicContentView()
                .environmentObject(prefs)
                .environmentObject(store)
                .environmentObject(runner)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat", action: store.newChat)
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(prefs)
                .environmentObject(store)
        }
    }
}
