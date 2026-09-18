import SwiftUI

@main
struct BarTApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

	var body: some Scene {
		// Pure menu bar app: no Window/WindowGroup.
		// AppDelegate owns the status item.
		Settings {
			EmptyView()
		}
	}
}
