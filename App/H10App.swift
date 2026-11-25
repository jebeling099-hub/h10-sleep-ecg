import SwiftUI
import SwiftData

@main
struct H10App: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.red)
                .modelContainer(AppEngine.shared.modelContainer)
                .onAppear {
                    AppEngine.shared.connect()
                }
        }
    }
}
