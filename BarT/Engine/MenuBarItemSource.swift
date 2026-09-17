import AppKit
import ApplicationServices
import CoreGraphics

/// Enumerates every menu bar item of every running app.
///
/// Read-only — this class changes nothing about the menu bar.
@MainActor
final class MenuBarItemSource: NSObject {
	private(set) var items: [MenuBarItem] = []

	/// Returns the window IDs that must never show up as items — BarT's own status items
	/// (icon, separators). Keyed by window ID rather than PID/bundle ID, because the latter
	/// are briefly attributed wrongly right after a drag (see ``MenuBarController``).
	///
	/// Deliberately a closure instead of a set: the separators only come into existence along
	/// the way, and between creating them and adding them to a set there would be a polling
	/// window of up to two seconds during which they slip through as perfectly ordinary,
	/// manageable items — with the result that the app starts moving its own separators.
	var excludedWindowIDs: () -> Set<CGWindowID> = { [] }

	/// Called only when the item list has actually changed.
	var onChange: (([MenuBarItem]) -> Void)?

	private var pollTask: Task<Void, Never>?

	/// CGS reports no changes; there is no notification for "item added". Hence polling as the
	/// baseline — the workspace notifications are only a latency improvement for the most
	/// common case (an app launching or quitting).
	private let pollInterval: Duration = .seconds(2)

	func start() {
		guard pollTask == nil else { return }
		refresh()
		pollTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: self?.pollInterval ?? .seconds(2))
				guard let self, !Task.isCancelled else { return }
				self.refresh()
			}
		}
		let center = NSWorkspace.shared.notificationCenter
		center.addObserver(
			self, selector: #selector(workspaceDidChange),
			name: NSWorkspace.didLaunchApplicationNotification, object: nil
		)
		center.addObserver(
			self, selector: #selector(workspaceDidChange),
			name: NSWorkspace.didTerminateApplicationNotification, object: nil
		)
	}

	func stop() {
		pollTask?.cancel()
		pollTask = nil
		NSWorkspace.shared.notificationCenter.removeObserver(self)
	}

	deinit {
		NSWorkspace.shared.notificationCenter.removeObserver(self)
	}

	/// Reads the menu bar right away, without waiting for the timer.
	@discardableResult
	func snapshot() -> [MenuBarItem] {
		items = Self.enumerate(excluding: excludedWindowIDs())
		return items
	}

	private func refresh() {
		let current = Self.enumerate(excluding: excludedWindowIDs())
		guard current != items else { return }
		items = current
		onChange?(current)
	}

	@objc
	private func workspaceDidChange(_ notification: Notification) {
		// A freshly launched app only registers its status item a few hundred milliseconds
		// after the launch notification.
		Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(750))
			self?.refresh()
		}
	}

	// MARK: Enumeration

	/// Window level of genuine status items. The menu bar itself (owner "Window Server") shows
	/// up in the same CGS list, but sits at level 24 and is not an item.
	private static let statusItemLayer = Int(CGWindowLevelForKey(.statusWindow))

	/// Maximum deviation between an item's AX and CGS center. Measured live: 0.0 pt. Items are
	/// at least 24 pt apart, which rules out a mismatch.
	private static let midXTolerance: CGFloat = 2

	/// Returns every menu bar item, ordered left to right.
	/// - Parameter excludedWindowIDs: windows that must never come back as items (BarT's own
	///   status items).
	static func enumerate(excluding excludedWindowIDs: Set<CGWindowID> = []) -> [MenuBarItem] {
		let windowIDs = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: false))
		guard !windowIDs.isEmpty else { return [] }
		let onScreen = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: true))

		// `CGWindowListCreateDescriptionFromArray` verifiably returns an empty list for menu
		// bar windows. So fetch the full window list instead and intersect it with the CGS
		// IDs — one call, ~100 entries.
		let descriptions = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
			as? [[String: Any]] ?? [])
			.filter { description in
				guard let windowID = description[kCGWindowNumber as String] as? CGWindowID else {
					return false
				}
				return windowIDs.contains(windowID)
					&& description[kCGWindowLayer as String] as? Int == statusItemLayer
			}

		let owners = accessibilityOwners()

		// Two passes: first collect the raw data and sort it by x, and only then assign the
		// sibling position per group (same bundleID+title) — that position needs the final
		// left-to-right order to be stable.
		struct RawItem {
			let windowID: CGWindowID
			let pid: pid_t
			let bundleID: String
			let title: String
			let frame: CGRect
			let isOnScreen: Bool
		}

		var raw: [RawItem] = []
		raw.reserveCapacity(descriptions.count)

		for description in descriptions {
			guard
				let windowID = description[kCGWindowNumber as String] as? CGWindowID,
				// Our own items (status icon, separators) never belong in the managed list:
				// they are not ordinary items the user can hide or show. Including them was
				// observed live to trigger an endless loop — the reconcile logic took the
				// (almost always "not visible") separator for a broken item and tried to
				// repair it forever.
				// Keyed by window ID rather than PID/bundle ID: both were live-observed to be
				// wrong right after a drag (misattributed to Control Center) — the window ID
				// is untouched by that race.
				!excludedWindowIDs.contains(windowID),
				let hostPID = description[kCGWindowOwnerPID as String] as? pid_t,
				// Frame read live via CGS rather than from kCGWindowBounds: the description is
				// a snapshot and measurably lags reality after a drag.
				let frame = CGSBridge.frame(for: windowID)
			else { continue }

			let owner = owners.first { abs($0.midX - frame.midX) <= midXTolerance }
			let pidValue = owner?.pid ?? hostPID

			let ownerName = description[kCGWindowOwnerName as String] as? String
			let bundleID = owner?.bundleID
				?? NSRunningApplication(processIdentifier: pidValue)?.bundleIdentifier
				?? ownerName
				?? "pid.\(pidValue)"

			raw.append(
				RawItem(
					windowID: windowID, pid: pidValue, bundleID: bundleID,
					title: description[kCGWindowName as String] as? String ?? "",
					frame: frame, isOnScreen: onScreen.contains(windowID)
				)
			)
		}
		raw.sort { $0.frame.minX < $1.frame.minX }

		func groupKey(_ item: RawItem) -> String {
			item.title.isEmpty ? item.bundleID : "\(item.bundleID):\(item.title)"
		}
		var groupCounts: [String: Int] = [:]
		for item in raw { groupCounts[groupKey(item), default: 0] += 1 }

		var seenSoFar: [String: Int] = [:]
		return raw.map { item in
			let key = groupKey(item)
			let index = seenSoFar[key, default: 0]
			seenSoFar[key] = index + 1
			let id = MenuBarItemID(
				windowID: item.windowID,
				ownerPID: item.pid,
				bundleID: item.bundleID,
				title: item.title,
				siblingIndex: index,
				siblingCount: groupCounts[key] ?? 1
			)
			return MenuBarItem(id: id, frame: item.frame, isOnScreen: item.isOnScreen)
		}
	}

	// MARK: Owner lookup via the accessibility API

	/// A menu bar item an app reports as its own.
	private struct ItemOwner {
		/// Horizontal center in global CG coordinates.
		let midX: CGFloat
		let pid: pid_t
		let bundleID: String
	}

	/// Reads each running app's *own* menu bar items.
	///
	/// `kCGWindowOwnerPID` is useless for status item windows: macOS renders them in a hosting
	/// process, so the window list reports the same PID for *all* items. Verified live on
	/// macOS 26.6.2 — all 21 items came back as `com.apple.controlcenter` (pid 674) although
	/// 11 different apps were involved. The CGS route (`CGSGetWindowOwner`) returns the same
	/// hosting connection and does not help either.
	///
	/// The only dependable source is the AX hierarchy: `kAXExtrasMenuBarAttribute` returns
	/// only an app's own items. The match is made on the horizontal center — the AX frames are
	/// inflated by 1 pt compared to the CGS frames, but the center matches exactly. (Same
	/// approach as in "Ice", MIT, github.com/jordanbaird/Ice.)
	private static func accessibilityOwners() -> [ItemOwner] {
		guard AccessibilityPermission.isTrusted else { return [] }

		var owners: [ItemOwner] = []
		for app in NSWorkspace.shared.runningApplications {
			let element = AXUIElementCreateApplication(app.processIdentifier)
			// Without a timeout one stuck process holds up the entire polling pass.
			AXUIElementSetMessagingTimeout(element, 1)

			var menuBarValue: CFTypeRef?
			guard
				AXUIElementCopyAttributeValue(
					element, kAXExtrasMenuBarAttribute as CFString, &menuBarValue
				) == .success,
				let menuBarValue,
				CFGetTypeID(menuBarValue) == AXUIElementGetTypeID()
			else { continue }

			var childrenValue: CFTypeRef?
			guard
				AXUIElementCopyAttributeValue(
					menuBarValue as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue
				) == .success,
				let children = childrenValue as? [AXUIElement]
			else { continue }

			let bundleID = app.bundleIdentifier
				?? app.localizedName
				?? "pid.\(app.processIdentifier)"

			for child in children {
				// Control Center also reports items that are not placed; those have a zero
				// frame and would otherwise match on center 0.
				guard let frame = axFrame(of: child), frame.width > 0 else { continue }
				owners.append(
					ItemOwner(midX: frame.midX, pid: app.processIdentifier, bundleID: bundleID)
				)
			}
		}
		return owners
	}

	private static func axFrame(of element: AXUIElement) -> CGRect? {
		var positionValue: CFTypeRef?
		var sizeValue: CFTypeRef?
		guard
			AXUIElementCopyAttributeValue(
				element, kAXPositionAttribute as CFString, &positionValue
			) == .success,
			AXUIElementCopyAttributeValue(
				element, kAXSizeAttribute as CFString, &sizeValue
			) == .success,
			let positionValue,
			let sizeValue,
			CFGetTypeID(positionValue) == AXValueGetTypeID(),
			CFGetTypeID(sizeValue) == AXValueGetTypeID()
		else { return nil }

		var origin = CGPoint.zero
		var size = CGSize.zero
		guard
			AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
			AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
		else { return nil }
		return CGRect(origin: origin, size: size)
	}

	/// Console dump for the debug menu item.
	static func debugDump() {
		let items = enumerate()
		let owners = Set(items.map(\.id.bundleID))
		print("[BarT] \(items.count) menu bar items from \(owners.count) apps (left → right):")
		if !AccessibilityPermission.isTrusted {
			print("[BarT]   Note: no accessibility permission — without it the owner lookup")
			print("[BarT]   falls back to the hosting process and is wrong.")
		}
		if items.contains(where: { $0.id.title.isEmpty }) {
			print("[BarT]   Note: items without a title cannot be persisted individually.")
		}
		for item in items {
			let flag = item.isOnScreen ? "visible" : "hidden "
			let frame = String(
				format: "x=%7.1f w=%5.1f", item.frame.minX, item.frame.width
			)
			print("[BarT]   \(flag)  \(frame)  win=\(item.windowID) pid=\(item.ownerPID)  \(item.storageKey)")
		}
	}
}
