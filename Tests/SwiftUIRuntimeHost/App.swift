import SwiftUI

// A real scene is required for drawViewHierarchy; SwiftPM's logic-test runner
// has no UIWindowScene and cannot exercise the screenshot transport contract.
@main struct RuntimeTestHost: App {
    var body: some Scene { WindowGroup { Color.white } }
}
