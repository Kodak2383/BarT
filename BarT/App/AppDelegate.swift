import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	var statusItem: NSStatusItem?
	var settingsWindow: NSWindow?

	/// Wird nur für die Dauer eines Rechtsklicks ans Status-Item gehängt — siehe
	/// ``statusItemClicked()``.
	private var statusMenu: NSMenu?

	let menuBarController = MenuBarController()

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Terminal-Zugriff auf die Debug-Ausgaben ohne Menü-Klick, nur wenn explizit gesetzt.
		let environment = ProcessInfo.processInfo.environment
		let wantsSelfTest = environment["BART_SELF_TEST"] != nil
		if environment["BART_DEBUG_DUMP"] != nil || wantsSelfTest {
			// Ungepuffert, sonst geht die Ausgabe verloren, wenn der Prozess (z.B. beim
			// Debuggen über eine umgeleitete Log-Datei) hart beendet wird.
			setvbuf(stdout, nil, _IONBF, 0)
		}
		if environment["BART_DEBUG_DUMP"] != nil {
			MenuBarItemSource.debugDump()
		}

		// Status-Item in der Menüleiste erstellen. WindowID vorher/nachher per Diff ermitteln
		// (gleiche Technik wie DragHideEngine für den Trenner) und beim Controller als
		// eigenes Fenster registrieren — es darf nie als verwaltbares Item auftauchen.
		// Bewusst VOR menuBarController.start(): der legt bei Bedarf selbst sofort einen
		// Trenner an (neue WindowID) — parallel dazu wäre die Diff-Erkennung hier
		// mehrdeutig und könnte die falsche neue WindowID greifen.
		let windowIDsBeforeStatusItem = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: false))
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

		if let button = statusItem?.button {
			button.image = NSImage(systemSymbolName: Self.collapsedSymbol, accessibilityDescription: "BarT")
			// Titel nur als Rückfall, falls das Symbol fehlt — sonst stünde das Kürzel aus
			// Phase 0 dauerhaft neben dem Icon.
			button.title = button.image == nil ? "BT" : ""
			// Bewusst über `action` statt `statusItem.menu`: ein gesetztes Menü fängt schon den
			// Linksklick ab, und der gehört der Reveal-Geste.
			button.target = self
			button.action = #selector(statusItemClicked)
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
		}

		// Menü mit Items erstellen
		let menu = NSMenu()

		// Settings Item
		menu.addItem(NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ","))

		// Separator
		menu.addItem(NSMenuItem.separator())

		// Debug-Werkzeuge. Rein lesend bzw. rein rechnend.
		menu.addItem(
			NSMenuItem(
				title: "Test: Alle Items auflisten (Debug)",
				action: #selector(debugListItems), keyEquivalent: ""
			)
		)
		menu.addItem(
			NSMenuItem(
				title: "Test: Layout-Selbsttest (Debug)",
				action: #selector(debugRunLayoutSelfTest), keyEquivalent: ""
			)
		)

		menu.addItem(NSMenuItem.separator())

		// Quit Item
		menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

		statusMenu = menu

		menuBarController.onRevealChanged = { [weak self] isRevealed in
			self?.updateStatusItemSymbol(isRevealed: isRevealed)
		}

		Task { [menuBarController] in
			// Neues Status-Item fährt animiert ein (siehe DragHideEngine); vorher gibt es
			// noch keine stabile WindowID zu finden.
			try? await Task.sleep(for: .milliseconds(600))
			if let ownWindowID = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: false))
				.subtracting(windowIDsBeforeStatusItem).first {
				menuBarController.excludeOwnWindow(ownWindowID)
			}
			// Erst jetzt starten: die eigene WindowID ist sicher ausgeschlossen, bevor der
			// Controller zum ersten Mal enumeriert und ggf. die Trenner anlegt.
			menuBarController.start()
			if wantsSelfTest {
				await menuBarController.runStartupSelfTest()
			}
		}
	}

	/// Symbol des eigenen Status-Items je nach Zustand. Der Pfeil zeigt, was der nächste Klick
	/// tut: ausklappen bzw. wieder einklappen.
	private static let collapsedSymbol = "menubar.arrow.down.rectangle"
	private static let revealedSymbol = "menubar.arrow.up.rectangle"

	/// Linksklick blendet die versteckten Items ein/aus, Rechtsklick öffnet das Menü.
	@objc
	private func statusItemClicked() {
		guard let statusItem, let button = statusItem.button else { return }

		if NSApp.currentEvent?.type == .rightMouseUp {
			// Nur für die Dauer dieses Klicks anhängen und sofort wieder lösen — `performClick`
			// blockiert, bis das Menü geschlossen ist.
			statusItem.menu = statusMenu
			button.performClick(nil)
			statusItem.menu = nil
			return
		}

		// ⌥-Klick zeigt zusätzlich „Immer versteckt“ — die Sektion, die die normale Geste
		// bewusst auslässt.
		let withOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
		menuBarController.toggleReveal(includingAlwaysHidden: withOption)
	}

	/// Hält das Symbol am Einblend-Zustand — der wechselt auch ohne Klick, sobald der Nutzer
	/// woanders hinklickt.
	private func updateStatusItemSymbol(isRevealed: Bool) {
		guard let button = statusItem?.button else { return }
		// Ohne Rückfall aufs alte Bild stünde die Menüleiste bei einem fehlenden Symbol leer da.
		button.image = NSImage(
			systemSymbolName: isRevealed ? Self.revealedSymbol : Self.collapsedSymbol,
			accessibilityDescription: "BarT"
		) ?? button.image
	}

	@objc
	func debugListItems() {
		MenuBarItemSource.debugDump()
	}

	@objc
	func debugRunLayoutSelfTest() {
		MenuBarLayout.runSelfTest()
		OscillationGuard.runSelfTest()
		Task { [menuBarController] in await menuBarController.runStartupSelfTest() }
	}

	@objc
	func openSettings() {
		// Prüfen, ob Fenster bereits offen ist
		if let existingWindow = settingsWindow, existingWindow.isVisible {
			existingWindow.makeKeyAndOrderFront(nil)
			NSApplication.shared.activate(ignoringOtherApps: true)
			return
		}

		// Neues Settings-Fenster erstellen
		let settingsView = SettingsView(controller: menuBarController)
		let hostingController = NSHostingController(rootView: settingsView)

		let window = NSWindow(contentViewController: hostingController)
		window.title = "BarT Einstellungen"
		window.setFrame(NSRect(x: 0, y: 0, width: 480, height: 360), display: false)
		window.center()
		window.styleMask = [.titled, .closable, .miniaturizable]
		window.isReleasedWhenClosed = false

		self.settingsWindow = window
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
	}
}
