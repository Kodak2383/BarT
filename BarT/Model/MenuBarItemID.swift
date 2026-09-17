import AppKit
import CoreGraphics

/// Runtime identity of a menu bar item.
///
/// `windowID` and `ownerPID` are valid within a single session only — both change as soon
/// as the owning app restarts. Persistence relies on ``storageKey`` exclusively.
struct MenuBarItemID: Hashable, Sendable {
	let windowID: CGWindowID
	let ownerPID: pid_t

	/// Bundle ID of the owning app, or its process name as a fallback.
	let bundleID: String

	/// The item's window title. Apps with several items (Control Center, SystemUIServer)
	/// differ by this alone.
	///
	/// In a live test on macOS 26 `kCGWindowName` returned meaningful titles ("CPU_mini",
	/// "WiFi", "Clock") even without screen recording permission. Measured live during
	/// phase 2: for the Control Center modules themselves the title is empty or identical —
	/// without ``siblingIndex`` they all collapse onto the same display name.
	let title: String

	/// 0-based position within the group of items sharing `bundleID`+`title`, ordered left
	/// to right. Resolves exactly the case where several items (all Control Center modules,
	/// say) would otherwise be indistinguishable.
	let siblingIndex: Int
	/// Size of that group. The position only shows up in ``storageKey`` and ``displayName``
	/// when the group has more than one member — apps with exactly one item keep the
	/// unchanged key they have had since phase 1.
	let siblingCount: Int

	/// The item's own accessibility identifier, where it has one — `com.apple.menuextra.wifi`
	/// and friends.
	///
	/// This is the one genuinely stable handle on an item: it is chosen by the owning app, not
	/// derived from where the item happens to sit. Where it exists it replaces the positional
	/// key entirely, which is what makes a stored assignment survive the user rearranging their
	/// menu bar. Only Apple's own menu extras supply it — third-party items have none.
	let identifier: String?

	/// Human-readable name from the accessibility hierarchy, if the app offers one.
	///
	/// Deliberately excluded from ``==`` and ``hash(into:)`` below: some of these carry live
	/// status ("WiFi, connected, 3 bars"), and an item whose identity changed every few seconds
	/// would make ``MenuBarItemSource`` report a changed list on every poll.
	let label: String?

	/// Key that stays stable across app restarts; the only field that ends up in ``MenuBarLayout``.
	///
	/// With an ``identifier`` this is exact. Without one it falls back to the positional key,
	/// which stays stable only as long as the order of identically named items does not change
	/// (by rearranging Control Center itself, for instance) — a known residual fuzziness.
	var storageKey: String {
		if let identifier, !identifier.isEmpty { return identifier }
		let base = title.isEmpty ? bundleID : "\(bundleID):\(title)"
		return siblingCount > 1 ? "\(base)#\(siblingIndex)" : base
	}

	var displayName: String {
		let appName = NSRunningApplication(processIdentifier: ownerPID)?.localizedName ?? bundleID
		if let label, !label.isEmpty {
			// The app name is only worth prefixing when it adds something. It does for
			// "Stats – CPU: Mini", but not for "Control Center – Control Center", and not for
			// "Vorssaint – Vorssaint: idle", where the app already named itself.
			guard !label.lowercased().hasPrefix(appName.lowercased()) else { return label }
			return "\(appName) – \(label)"
		}
		// Window titles like "Item-0" are placeholders an app never meant as a name. They still
		// serve as a key in ``storageKey``, but showing them helps nobody.
		let named = title.hasPrefix("Item-") ? "" : title
		let base = named.isEmpty ? appName : "\(appName) – \(named)"
		return siblingCount > 1 ? "\(base) (\(siblingIndex + 1))" : base
	}

	// Identity covers everything except ``label`` — see there.
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.windowID == rhs.windowID && lhs.ownerPID == rhs.ownerPID
			&& lhs.bundleID == rhs.bundleID && lhs.title == rhs.title
			&& lhs.siblingIndex == rhs.siblingIndex && lhs.siblingCount == rhs.siblingCount
			&& lhs.identifier == rhs.identifier
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(windowID)
		hasher.combine(ownerPID)
		hasher.combine(bundleID)
		hasher.combine(title)
		hasher.combine(siblingIndex)
		hasher.combine(siblingCount)
		hasher.combine(identifier)
	}
}

/// A menu bar item together with its current geometry.
struct MenuBarItem: Hashable, Sendable {
	let id: MenuBarItemID

	/// Global CG coordinates (origin top left), see ``CGSBridge/frame(for:)``.
	let frame: CGRect

	/// `false` once the item has been pushed out of the visible area — that is, exactly
	/// when the separator hides it.
	let isOnScreen: Bool

	var windowID: CGWindowID { id.windowID }
	var ownerPID: pid_t { id.ownerPID }
	var storageKey: String { id.storageKey }
	var displayName: String { id.displayName }
}
