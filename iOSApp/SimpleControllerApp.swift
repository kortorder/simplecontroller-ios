import SwiftUI

@main
@MainActor
struct SimpleControllerApp: App {
    @UIApplicationDelegateAdaptor(ControllerOrientationAppDelegate.self) private var orientationDelegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
