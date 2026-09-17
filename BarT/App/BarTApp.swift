import SwiftUI

@main
struct BarTApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

	var body: some Scene {
		// Reine Menüleisten-App — keine Window/WindowGroup
		// AppDelegate verwaltet das Status-Item
		Settings {
			EmptyView()
		}
	}
}
