import SwiftUI

@main
struct TopBarApp: App {
    // Shared app-wide state, used by the notch panel.
    static let store = PullRequestStore()
    static let custom = CustomStore()

    @NSApplicationDelegateAdaptor(NotchController.self) private var notch

    init() {
        Pref.register()
    }

    var body: some Scene {
        // Everything lives in the notch; the menu bar icon (see NotchController) just opens settings.
        // An App needs at least one scene, and this one never shows on its own.
        Settings { EmptyView() }
    }
}
