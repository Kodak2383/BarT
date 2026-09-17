import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	var statusItem: NSStatusItem?
	var settingsWindow: NSWindow?

	/// Attached to the status item for the duration of a right-click only — see
	/// ``statusItemClicked()``.
	private var statusMenu: NSMenu?

	/// Shown only while ⌥ is held — see ``menuNeedsUpdate(_:)``.
	private var debugMenuItems: [NSMenuItem] = []

	let menuBarController = MenuBarController()

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Terminal access to the debug output without a menu click, only when explicitly set.
		let environment = ProcessInfo.processInfo.environment
		let wantsSelfTest = environment["BART_SELF_TEST"] != nil
		if environment["BART_DEBUG_DUMP"] != nil || wantsSelfTest {
			// Unbuffered, otherwise the output is lost when the process is killed hard (while
			// debugging through a redirected log file, for instance).
			setvbuf(stdout, nil, _IONBF, 0)
		}
		if environment["BART_DEBUG_DUMP"] != nil {
			MenuBarItemSource.debugDump()
		}
		if environment["BART_OPEN_SETTINGS"] != nil {
			// The settings window is otherwise only reachable by right-clicking the status
			// item, which makes it awkward to look at while working on it.
			Task { try? await Task.sleep(for: .seconds(2)); self.openSettings() }
		}

		// Create the status item in the menu bar. Determine its window ID by diffing before
		// and after (the same technique DragHideEngine uses for the separators) and register
		// it with the controller as our own window — it must never show up as a manageable
		// item. Deliberately BEFORE menuBarController.start(): that call may immediately
		// create a separator of its own (a new window ID), and in parallel the diff here
		// would be ambiguous and could grab the wrong new window ID.
		let windowIDsBeforeStatusItem = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: false))
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

		if let button = statusItem?.button {
			button.image = NSImage(systemSymbolName: Self.collapsedSymbol, accessibilityDescription: "BarT")
			// The title is a fallback for a missing symbol only — otherwise the phase 0
			// abbreviation would sit next to the icon permanently.
			button.title = button.image == nil ? "BT" : ""
			// Deliberately via `action` rather than `statusItem.menu`: an assigned menu already
			// swallows the left click, and that one belongs to the reveal gesture.
			button.target = self
			button.action = #selector(statusItemClicked)
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
		}

		// Build the menu.
		let menu = NSMenu()
		menu.delegate = self

		menu.addItem(NSMenuItem(title: "About BarT", action: #selector(showAbout), keyEquivalent: ""))
		menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))

		// Debug tools. Purely read-only or purely computational, and hidden unless ⌥ is held —
		// see ``menuNeedsUpdate(_:)``. They are useful while working on the app and only
		// clutter the menu for everyone else.
		let debugSeparator = NSMenuItem.separator()
		let listItems = NSMenuItem(
			title: "List all items (debug)", action: #selector(debugListItems), keyEquivalent: ""
		)
		let selfTest = NSMenuItem(
			title: "Run self-tests (debug)", action: #selector(debugRunLayoutSelfTest), keyEquivalent: ""
		)
		debugMenuItems = [debugSeparator, listItems, selfTest]
		for item in debugMenuItems {
			item.isHidden = true
			menu.addItem(item)
		}

		menu.addItem(NSMenuItem.separator())

		// Quit item
		menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

		statusMenu = menu

		menuBarController.onRevealChanged = { [weak self] isRevealed in
			self?.updateStatusItemSymbol(isRevealed: isRevealed)
		}

		Task { [menuBarController] in
			// A new status item slides in with an animation (see DragHideEngine); before that
			// there is no stable window ID to find.
			try? await Task.sleep(for: .milliseconds(600))
			if let ownWindowID = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: false))
				.subtracting(windowIDsBeforeStatusItem).first {
				menuBarController.excludeOwnWindow(ownWindowID)
			}
			// Only start now: our own window ID is safely excluded before the controller
			// enumerates for the first time and creates the separators.
			await menuBarController.start()
			if wantsSelfTest {
				await menuBarController.runStartupSelfTest()
			}
		}
	}

	/// Symbol of our own status item, depending on state. The chevrons point the way the items
	/// will travel on the next click: while collapsed they sit off to the left and come back
	/// rightwards into view, and while revealed the next click pushes them left again. Pointing
	/// left and right rather than up and down, because that is the axis the bar actually moves on.
	///
	/// Double chevrons on purpose: the separator items carry a single `chevron.compact.left`,
	/// and while revealed they are visible right next to this icon.
	private static let collapsedSymbol = "chevron.right.2"
	private static let revealedSymbol = "chevron.left.2"

	/// A left click reveals or hides the hidden items, a right click opens the menu.
	@objc
	private func statusItemClicked() {
		guard let statusItem, let button = statusItem.button else { return }

		if NSApp.currentEvent?.type == .rightMouseUp {
			// Attach for the duration of this click only and detach right after —
			// `performClick` blocks until the menu closes.
			statusItem.menu = statusMenu
			button.performClick(nil)
			statusItem.menu = nil
			return
		}

		// ⌥-click additionally reveals “Always hidden” — the section the plain gesture
		// deliberately leaves out.
		let withOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
		menuBarController.toggleReveal(includingAlwaysHidden: withOption)
	}

	/// Keeps the symbol in sync with the reveal state — which also changes without a click,
	/// as soon as the user clicks somewhere else.
	private func updateStatusItemSymbol(isRevealed: Bool) {
		guard let button = statusItem?.button else { return }
		// Without falling back to the old image a missing symbol would leave the menu bar blank.
		button.image = NSImage(
			systemSymbolName: isRevealed ? Self.revealedSymbol : Self.collapsedSymbol,
			accessibilityDescription: "BarT"
		) ?? button.image
	}

	/// The standard panel already reads name, version and icon from the bundle — there is
	/// nothing here worth writing by hand.
	@objc
	func showAbout() {
		NSApplication.shared.activate(ignoringOtherApps: true)
		// The GPL asks for the notice to travel with the *program*, not just with the repository —
		// so it belongs in the panel rather than only in a file nobody who downloads a zip reads.
		let credits = NSAttributedString(
			string: """
				BarT is free software under the GPL-3.0 licence.
				It contains code from Ice (GPL-3.0) by Jordan Baird.
				""",
			attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
		)
		NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
	}

	@objc
	func debugListItems() {
		MenuBarItemSource.debugDump()
	}

	@objc
	func debugRunLayoutSelfTest() {
		Task { [menuBarController] in await menuBarController.runStartupSelfTest() }
	}

	@objc
	func openSettings() {
		// Reuse the window if it is already open.
		if let existingWindow = settingsWindow, existingWindow.isVisible {
			existingWindow.makeKeyAndOrderFront(nil)
			NSApplication.shared.activate(ignoringOtherApps: true)
			return
		}

		// Build a new settings window.
		let settingsView = SettingsView(controller: menuBarController)
		let hostingController = NSHostingController(rootView: settingsView)

		let window = NSWindow(contentViewController: hostingController)
		window.title = "BarT Settings"
		window.setFrame(NSRect(x: 0, y: 0, width: 520, height: 480), display: false)
		window.center()
		// Resizable because the Items tab holds a list as long as the user's menu bar is — the
		// minimum size comes from SettingsView.
		window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
		window.isReleasedWhenClosed = false

		self.settingsWindow = window
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
	}
}

extension AppDelegate: NSMenuDelegate {
	/// Runs just before the menu is drawn, which is the only moment at which the modifier state
	/// is the one the user is actually holding.
	func menuNeedsUpdate(_ menu: NSMenu) {
		let showsDebug = NSEvent.modifierFlags.contains(.option)
		for item in debugMenuItems {
			item.isHidden = !showsDebug
		}
	}
}
