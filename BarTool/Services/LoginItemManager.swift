import ServiceManagement

/// Verwaltet die Auto-Launch-Einstellung via Login Items
/// (noch nicht in der UI verdrahtet — nur bereitgestellt für Phase 1+)
class LoginItemManager {
	/// Registriert die App als Login Item
	func register() throws {
		try SMAppService.mainApp.register()
	}

	/// Deregistriert die App aus Login Items
	func unregister() throws {
		try SMAppService.mainApp.unregister()
	}

	/// Prüft, ob die App aktuell als Login Item registriert ist
	func isRegistered() -> Bool {
		SMAppService.mainApp.status == .enabled
	}
}
