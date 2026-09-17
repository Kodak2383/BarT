import ServiceManagement

/// Manages the auto-launch setting via Login Items.
class LoginItemManager {
	/// Registers the app as a login item.
	func register() throws {
		try SMAppService.mainApp.register()
	}

	/// Removes the app from the login items.
	func unregister() throws {
		try SMAppService.mainApp.unregister()
	}

	/// Whether the app is currently registered as a login item.
	func isRegistered() -> Bool {
		SMAppService.mainApp.status == .enabled
	}
}
