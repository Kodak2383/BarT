import ApplicationServices

/// Accessibility permission. Without it no foreign process accepts the drag engine's
/// synthetic mouse events; plain enumeration works either way.
enum AccessibilityPermission {
	static var isTrusted: Bool {
		AXIsProcessTrusted()
	}

	/// Opens the system dialog unless permission was already granted.
	///
	/// macOS shows that dialog only once per binary. After a rebuild with a changed
	/// signature the app counts as new and has to be re-approved in System Settings —
	/// during development the most common reason for "the drag does nothing".
	@discardableResult
	static func requestAccess() -> Bool {
		// A literal instead of `kAXTrustedCheckOptionPrompt`: the constant is imported as a
		// global `var` and is therefore inaccessible under Swift 6 strict concurrency. Its
		// value has not changed since the API was introduced.
		return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
	}
}
