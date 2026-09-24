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

	/// True once `register()` has gone through but the user still has to approve BarT in
	/// System Settings. `register()` can return without throwing and leave the app in exactly
	/// this state, so a caller has to check it separately from catching an error.
	var needsApproval: Bool {
		SMAppService.mainApp.status == .requiresApproval
	}

	/// Opens System Settings › General › Login Items, where the approval above is granted.
	func openSystemSettings() {
		SMAppService.openSystemSettingsLoginItems()
	}
}
