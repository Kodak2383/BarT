import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	var statusItem: NSStatusItem?
	var settingsWindow: NSWindow?
	var welcomeWindow: NSWindow?

	/// Set the first time the welcome window is shown. Deleting the defaults domain
	/// (`defaults delete de.andreduhme.BarT`) is what makes a first launch happen again.
	private static let hasSeenWelcomeKey = "hasSeenWelcome"

	/// Attached to the status item for the duration of a right-click only. See
	/// ``statusItemClicked()``.
	private var statusMenu: NSMenu?

	/// Shown only while ⌥ is held. See ``menuNeedsUpdate(_:)``.
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

		// Create the status item in the menu bar. Its window ID is found by diffing the menu
		// bar list before and after, the same way the separators find theirs, and registered
		// with the controller as our own window, which must never show up as a manageable
		// item. Deliberately BEFORE menuBarController.start(): that call may immediately
		// create a separator of its own (a new window ID), and in parallel the diff here
		// would be ambiguous and could grab the wrong new window ID.
		let windowIDsBeforeStatusItem = Set(CGSBridge.menuBarWindowIDs())
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		// A self-test instance runs next to the user's copy and shares its defaults: under its
		// own name it cannot overwrite where the user put the icon ("Item-0").
		if wantsSelfTest { statusItem?.autosaveName = "BarTSelfTestIcon" }

		if let button = statusItem?.button {
			button.image = NSImage(systemSymbolName: Self.collapsedSymbol, accessibilityDescription: "BarT")
			// The title is a fallback for a missing symbol only. Otherwise the phase 0
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
		menu.addItem(
			NSMenuItem(title: "Welcome to BarT", action: #selector(showWelcome), keyEquivalent: "")
		)
		menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))

		// Debug tools. Purely read-only or purely computational, and hidden unless ⌥ is held;
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

		// Last, so the window lands on top of a menu bar that is already in place, and after
		// the status item exists, because it is the thing the text points at.
		if !UserDefaults.standard.bool(forKey: Self.hasSeenWelcomeKey) {
			showWelcome()
		}

		menuBarController.onRevealChanged = { [weak self] isRevealed in
			self?.updateStatusItemSymbol(isRevealed: isRevealed)
		}

		Task { [menuBarController] in
			// Waits for the slide-in to settle rather than guessing at it; this used to sleep
			// a fixed 600 ms and take whichever new ID came first.
			if let ownWindowID = await CGSBridge.newMenuBarWindowID(notIn: windowIDsBeforeStatusItem) {
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
			// Attach for the duration of this click only and detach right after:
			// `performClick` blocks until the menu closes.
			statusItem.menu = statusMenu
			button.performClick(nil)
			statusItem.menu = nil
			return
		}

		// ⌥-click additionally reveals “Always hidden”, the section the plain gesture
		// deliberately leaves out.
		let withOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
		menuBarController.toggleReveal(includingAlwaysHidden: withOption)
	}

	/// Keeps the symbol in sync with the reveal state, which also changes without a click,
	/// as soon as the user clicks somewhere else.
	private func updateStatusItemSymbol(isRevealed: Bool) {
		guard let button = statusItem?.button else { return }
		// Without falling back to the old image a missing symbol would leave the menu bar blank.
		button.image = NSImage(
			systemSymbolName: isRevealed ? Self.revealedSymbol : Self.collapsedSymbol,
			accessibilityDescription: "BarT"
		) ?? button.image
	}

	/// The first-launch window, and the menu entry that brings it back.
	@objc
	func showWelcome() {
		UserDefaults.standard.set(true, forKey: Self.hasSeenWelcomeKey)
		// Not resizable: the text is laid out for one width, and there is nothing in here that
		// gets better with more room.
		present(&welcomeWindow, title: "Welcome to BarT", styleMask: [.titled, .closable]) {
			NSHostingController(rootView: WelcomeView { [weak self] in self?.welcomeWindow?.close() })
		}
	}

	/// Brings one of BarT's two windows to the front, building it on first use.
	///
	/// Both of them are singletons that outlive their own close (`isReleasedWhenClosed` is off),
	/// and both have to raise the app as well: BarT is an accessory app, so a window it orders
	/// front while another app is active would open behind that app.
	private func present(
		_ window: inout NSWindow?,
		title: String,
		styleMask: NSWindow.StyleMask,
		size: NSSize? = nil,
		content: () -> NSViewController
	) {
		defer { NSApplication.shared.activate(ignoringOtherApps: true) }
		if let window, window.isVisible {
			window.makeKeyAndOrderFront(nil)
			return
		}
		let new = NSWindow(contentViewController: content())
		new.title = title
		new.styleMask = styleMask
		new.isReleasedWhenClosed = false
		new.delegate = self
		if let size { new.setFrame(NSRect(origin: .zero, size: size), display: false) }
		new.center()
		window = new
		new.makeKeyAndOrderFront(nil)
	}

	/// The standard panel already reads name, version and icon from the bundle, so there is
	/// nothing here worth writing by hand.
	@objc
	func showAbout() {
		NSApplication.shared.activate(ignoringOtherApps: true)
		// The GPL asks for the notice to travel with the *program*, not just with the repository,
		// so it belongs in the panel and not only in a file nobody who downloads a zip reads.
		//
		// The licence and nothing else. This used to add "contains code from Ice", which tells a
		// reader that foreign code is running in here; what is actually left of that is six
		// declarations of Apple's own private API (see `Bridging.swift`). The full provenance
		// belongs in THIRD-PARTY-LICENSES.md, not in a panel three lines long.
		let credits = NSAttributedString(
			string: "BarT is free software under the GPL-3.0 licence.",
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
		// Only the settings window reads the item list, so this is where watching starts.
		// Safe to call every time, even while the window is already open: see
		// ``MenuBarController/startWatching()``.
		menuBarController.startWatching()
		// Resizable because the Items tab holds a list as long as the user's menu bar is. The
		// minimum size comes from SettingsView.
		present(
			&settingsWindow,
			title: "BarT Settings",
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			size: NSSize(width: 520, height: 480)
		) {
			NSHostingController(rootView: SettingsView(controller: menuBarController))
		}
	}
}

extension AppDelegate: NSWindowDelegate {
	/// Stops watching as soon as the settings window closes: it is the only reader of the item
	/// list, so nothing is left to poll for. The welcome window shares this delegate too, but
	/// closing it does not match ``settingsWindow`` and falls through.
	func windowWillClose(_ notification: Notification) {
		guard notification.object as? NSWindow === settingsWindow else { return }
		menuBarController.stopWatching()
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
