import ApplicationServices

/// Bedienungshilfen-Berechtigung. Ohne sie nimmt kein fremder Prozess die synthetischen
/// Maus-Events der Drag-Engine an; die reine Enumeration funktioniert dagegen auch ohne.
enum AccessibilityPermission {
	static var isTrusted: Bool {
		AXIsProcessTrusted()
	}

	/// Öffnet den Systemdialog, falls noch nicht erteilt.
	///
	/// macOS zeigt den Dialog pro Binary nur einmal. Nach einem Neubau mit geänderter
	/// Signatur gilt die App als neu und muss in den Systemeinstellungen erneut
	/// freigeschaltet werden — beim Entwickeln der häufigste Grund für "Drag tut nichts".
	@discardableResult
	static func requestAccess() -> Bool {
		// Literal statt `kAXTrustedCheckOptionPrompt`: die Konstante ist als globale `var`
		// importiert und unter Swift 6 Strict Concurrency nicht zugreifbar. Der Wert ist
		// seit Einführung der API unverändert.
		return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
	}
}
