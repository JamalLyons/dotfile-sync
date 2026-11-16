// DotfileSync.app entry point. Everything else lives in App/Shared, which the unit-test bundle
// compiles too, so tests never launch (or register) the app.

import SwiftUI

@main
struct DotfileSyncApp: App {
    var body: some Scene {
        WindowGroup("DotfileSync") {
            DotfileSyncRootView()
                .frame(minWidth: 760, minHeight: 480)
        }
    }
}
