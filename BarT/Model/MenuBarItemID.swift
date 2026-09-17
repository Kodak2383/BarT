import AppKit
import CoreGraphics

/// Runtime identity of a menu bar item.
///
/// Valid within a single session only — `windowID` and `ownerPID` both change as soon as the
/// owning app restarts. Nothing here is persisted: which section an item belongs to is read from
/// where it sits relative to the separators, and macOS remembers that arrangement itself.
struct MenuBarItemID: Hashable, Sendable {
	let windowID: CGWindowID

	/// The *hosting* process for Apple's own items — macOS renders menu extras out of process,
	/// so all of them report Control Center. Determining the true owner needed the accessibility
	/// permission, which BarT no longer asks for; see ``displayName`` for the consequence.
	let ownerPID: pid_t

	/// Bundle ID of the hosting app, or its process name as a fallback.
	let bundleID: String

	/// The item's window title, from `kCGWindowName` — "WiFi", "Clock", "CPU_mini". Measured on
	/// macOS 26: these come through without any permission at all.
	let title: String

	/// What the items view shows.
	///
	/// The title comes first, deliberately. Since the owner lookup went away with the drag
	/// engine, the app name is the hosting process for every one of Apple's menu extras — eight
	/// rows of "Control Center" say less than "WiFi", "Battery", "Clock".
	var displayName: String {
		// Titles like "Item-0" are placeholders an app never meant as a name.
		let named = title.hasPrefix("Item-") ? "" : title
		if !named.isEmpty { return named }
		return NSRunningApplication(processIdentifier: ownerPID)?.localizedName ?? bundleID
	}
}

/// A menu bar item together with its current geometry.
struct MenuBarItem: Hashable, Sendable {
	let id: MenuBarItemID

	/// Global CG coordinates (origin top left), see ``CGSBridge/frame(for:)``.
	let frame: CGRect

	/// `false` once the item has been pushed out of the visible area — that is, exactly when a
	/// separator hides it.
	let isOnScreen: Bool

	var windowID: CGWindowID { id.windowID }
	var ownerPID: pid_t { id.ownerPID }
	var displayName: String { id.displayName }
}
