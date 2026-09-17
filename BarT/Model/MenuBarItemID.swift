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

	/// Key that stays stable across app restarts; the only field that ends up in ``MenuBarLayout``.
	///
	/// It stays stable only as long as the order of identically named items does not change
	/// (by rearranging Control Center itself, for instance) — a known residual fuzziness,
	/// see ``siblingIndex``.
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
