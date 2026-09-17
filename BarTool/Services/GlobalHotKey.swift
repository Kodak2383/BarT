import Carbon.HIToolbox

/// Eine systemweit registrierte Tastenkombination.
///
/// Bewusst über die Carbon-Hotkey-API statt über `NSEvent.addGlobalMonitorForEvents`: ein
/// globaler Tastatur-Monitor bekäme *jeden* Tastendruck des Nutzers zu sehen — auch Passwörter
/// — und würde die Kombination trotzdem zusätzlich an die Vordergrund-App durchreichen.
/// `RegisterEventHotKey` registriert genau diese eine Kombination und fängt sie ab.
///
/// ponytail: fest verdrahtet statt konfigurierbar. Ein Tastenkürzel-Recorder wäre mehr UI als
/// die restlichen Einstellungen zusammen; bei einer Kollision meldet ``isRegistered`` `false`
/// und die Einstellungen sagen es. Konfigurierbar machen, wenn jemand über die Belegung
/// stolpert.
///
/// Lebt so lange wie die App — deshalb kein `deinit`, der nur beim Beenden liefe.
@MainActor
final class GlobalHotKey {
	/// ⌃⌥⌘B. Drei Modifier, damit es niemandem in die Quere kommt.
	static let displayName = "⌃⌥⌘B"

	private var hotKeyRef: EventHotKeyRef?
	private var eventHandler: EventHandlerRef?

	/// `false`, wenn die Kombination bereits vergeben ist oder Carbon sie ablehnt.
	private(set) var isRegistered = false

	init(action: @escaping @MainActor () -> Void) {
		registeredAction = action

		var eventType = EventTypeSpec(
			eventClass: OSType(kEventClassKeyboard),
			eventKind: UInt32(kEventHotKeyPressed)
		)
		guard InstallEventHandler(
			GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &eventHandler
		) == noErr else { return }

		// Signatur ist frei wählbar, muss nur app-weit eindeutig sein: "BTHK".
		let id = EventHotKeyID(signature: 0x4254_484B, id: 1)
		guard RegisterEventHotKey(
			UInt32(kVK_ANSI_B),
			UInt32(controlKey | optionKey | cmdKey),
			id,
			GetApplicationEventTarget(),
			0,
			&hotKeyRef
		) == noErr else { return }

		isRegistered = true
	}
}

/// Aktion des einen registrierten Hotkeys.
///
/// Der Carbon-Handler unten ist ein reiner C-Funktionszeiger und kann nichts einfangen — der
/// Umweg über eine Datei-globale Variable ist dafür der vorgesehene Weg. Geschrieben wird sie
/// nur aus ``GlobalHotKey/init(action:)``, gelesen nur im Handler, und beides läuft auf dem
/// Main-Thread.
private nonisolated(unsafe) var registeredAction: (@MainActor () -> Void)?

private func hotKeyEventHandler(
	_ nextHandler: EventHandlerCallRef?,
	_ event: EventRef?,
	_ userData: UnsafeMutableRawPointer?
) -> OSStatus {
	// Carbon stellt Hotkey-Events im Main-Event-Loop zu.
	MainActor.assumeIsolated { registeredAction?() }
	return noErr
}
