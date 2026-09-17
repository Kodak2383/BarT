import AppKit
import CoreGraphics

/// Laufzeit-Identität eines Menüleisten-Items.
///
/// `windowID` und `ownerPID` sind nur innerhalb einer Sitzung gültig — beide ändern sich,
/// sobald die besitzende App neu startet. Für Persistenz dient ausschließlich ``storageKey``.
struct MenuBarItemID: Hashable, Sendable {
	let windowID: CGWindowID
	let ownerPID: pid_t

	/// Bundle-ID der besitzenden App, sonst deren Prozessname.
	let bundleID: String

	/// Fenstertitel des Items. Apps mit mehreren Items (Kontrollzentrum, SystemUIServer)
	/// unterscheiden sich nur hierüber.
	///
	/// In einem Live-Test auf macOS 26 lieferte `kCGWindowName` auch ohne
	/// Bildschirmaufnahme-Berechtigung sprechende Titel ("CPU_mini", "WiFi", "Clock").
	/// Live in Phase 2 gemessen: für die Kontrollzentrum-Module selbst ist der Titel leer
	/// oder identisch — ohne ``siblingIndex`` fallen sie alle auf denselben Anzeigenamen
	/// zusammen.
	let title: String

	/// 0-basierte Position innerhalb der Gruppe von Items mit identischem `bundleID`+`title`,
	/// in Reihenfolge von links nach rechts. Löst genau den Fall auf, in dem mehrere Items
	/// (z.B. alle Kontrollzentrum-Module) sich sonst nicht unterscheiden ließen.
	let siblingIndex: Int
	/// Größe dieser Gruppe. Nur bei mehr als einem Mitglied wird die Position überhaupt
	/// in ``storageKey`` und ``displayName`` sichtbar — Apps mit genau einem Item behalten
	/// ihren unveränderten, seit Phase 1 stabilen Schlüssel.
	let siblingCount: Int

	/// Über App-Neustarts hinweg stabiler Schlüssel; einziges Feld, das in ``MenuBarLayout`` landet.
	///
	/// Bleibt nur stabil, solange sich die Reihenfolge gleichnamiger Items nicht ändert
	/// (z.B. durch Umsortieren im Kontrollzentrum selbst) — bekannte Restunschärfe, siehe
	/// ``siblingIndex``.
	var storageKey: String {
		let base = title.isEmpty ? bundleID : "\(bundleID):\(title)"
		return siblingCount > 1 ? "\(base)#\(siblingIndex)" : base
	}

	var displayName: String {
		let appName = NSRunningApplication(processIdentifier: ownerPID)?.localizedName ?? bundleID
		let base = title.isEmpty ? appName : "\(appName) – \(title)"
		return siblingCount > 1 ? "\(base) (\(siblingIndex + 1))" : base
	}
}

/// Ein Menüleisten-Item mit seiner aktuellen Geometrie.
struct MenuBarItem: Hashable, Sendable {
	let id: MenuBarItemID

	/// Globale CG-Koordinaten (Ursprung oben links), siehe ``CGSBridge/frame(for:)``.
	let frame: CGRect

	/// `false`, sobald das Item aus dem sichtbaren Bereich geschoben wurde — also genau
	/// dann, wenn es durch den Trenner versteckt ist.
	let isOnScreen: Bool

	var windowID: CGWindowID { id.windowID }
	var ownerPID: pid_t { id.ownerPID }
	var storageKey: String { id.storageKey }
	var displayName: String { id.displayName }
}
