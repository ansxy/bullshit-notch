import SwiftUI

@main
struct TopBarApp: App {
    @StateObject private var store = PullRequestStore()
    @StateObject private var customStore = CustomStore()

    var body: some Scene {
        MenuBarExtra("PRs", systemImage: "arrow.triangle.branch") {
            ContentView()
                .environmentObject(store)
                .environmentObject(customStore)
        }
        .menuBarExtraStyle(.window)
    }
}
