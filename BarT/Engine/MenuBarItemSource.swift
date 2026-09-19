import AppKit
import CoreGraphics

/// Enumerates every menu bar item of every running app.
///
/// Read-only: this class changes nothing about the menu bar.
@MainActor
final class MenuBarItemSource: NSObject {
	private(set) var items: [MenuBarItem] = []

	/// Returns the window IDs that must never show up as items: BarT's own status items
	/// (icon, separators).
	///
	/// Deliberately a closure instead of a set: the separators come into existence a moment
	/// after launch, and between creating them and adding them to a set there would be a
	/// polling window of up to two seconds during which they show up as ordinary items.
	var excludedWindowIDs: () -> Set<CGWindowID> = { [] }

	/// Called only when the item list has actually changed.
	var onChange: (([MenuBarItem]) -> Void)?

	private var pollTask: Task<Void, Never>?
	/// The one refresh a burst of launch/quit notifications is allowed to schedule.
	private var pendingRefresh: Task<Void, Never>?

	/// CGS reports no changes; there is no notification for "item added". Hence polling as the
	/// baseline; the workspace notifications are only a latency improvement for the most
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
		// after the launch notification. One pending refresh, not one per notification: at
		// login a dozen apps report within the same window, and each refresh is a full
		// enumeration that would find the same bar.
		pendingRefresh?.cancel()
		pendingRefresh = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(750))
			guard !Task.isCancelled else { return }
			self?.refresh()
		}
	}

	// MARK: Enumeration

	/// Window level of genuine status items. The menu bar itself (owner "Window Server") shows
	/// up in the same CGS list, but sits at level 24 and is not an item.
	private static let statusItemLayer = Int(CGWindowLevelForKey(.statusWindow))

	/// Returns every menu bar item, ordered left to right.
	/// - Parameter excludedWindowIDs: windows that must never come back as items (BarT's own
	///   status items).
	static func enumerate(excluding excludedWindowIDs: Set<CGWindowID> = []) -> [MenuBarItem] {
		let windowIDs = Set(CGSBridge.menuBarWindowIDs())
		guard !windowIDs.isEmpty else { return [] }
		let onScreen = windowIDs.intersection(CGSBridge.onScreenWindowIDs())

		// `CGWindowListCreateDescriptionFromArray` verifiably returns an empty list for menu
		// bar windows. So fetch the full window list instead and intersect it with the CGS
		// IDs: one call, ~100 entries.
		let descriptions = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
			as? [[String: Any]] ?? [])
			.filter { description in
				guard let windowID = description[kCGWindowNumber as String] as? CGWindowID else {
					return false
				}
				return windowIDs.contains(windowID)
					&& description[kCGWindowLayer as String] as? Int == statusItemLayer
			}

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
				// Our own items (status icon, separators) never belong in the list: they are
				// not items the user arranges. Keyed by window ID rather than PID/bundle ID,
				// because every status item reports the same hosting process, and a PID would
				// exclude half the bar.
				!excludedWindowIDs.contains(windowID),
				let pid = description[kCGWindowOwnerPID as String] as? pid_t,
				// Frame read live via CGS rather than from kCGWindowBounds: the description is
				// a snapshot and measurably lags reality.
				let frame = CGSBridge.frame(for: windowID)
			else { continue }

			let ownerName = description[kCGWindowOwnerName as String] as? String
			let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
				?? ownerName
				?? "pid.\(pid)"

			raw.append(
				RawItem(
					windowID: windowID, pid: pid, bundleID: bundleID,
					title: description[kCGWindowName as String] as? String ?? "",
					frame: frame, isOnScreen: onScreen.contains(windowID)
				)
			)
		}
		raw.sort { $0.frame.minX < $1.frame.minX }

		return raw.map { item in
			MenuBarItem(
				id: MenuBarItemID(
					windowID: item.windowID, ownerPID: item.pid,
					bundleID: item.bundleID, title: item.title
				),
				frame: item.frame, isOnScreen: item.isOnScreen
			)
		}
	}

	/// Console dump for the debug menu item.
	static func debugDump() {
		let items = enumerate()
		print("[BarT] \(items.count) menu bar items (left → right):")
		if !ScreenRecordingPermission.isGranted {
			print("[BarT]   Note: no screen recording permission: macOS withholds the window")
			print("[BarT]   titles, so names fall back to the hosting app. Beware: a binary")
			print("[BarT]   started straight from a terminal inherits the terminal's permission")
			print("[BarT]   and shows names the installed app does not get.")
		}
		for item in items {
			let flag = item.isOnScreen ? "visible" : "hidden "
			let frame = String(
				format: "x=%7.1f w=%5.1f", item.frame.minX, item.frame.width
			)
			print("[BarT]   \(flag)  \(frame)  win=\(item.windowID)  \(item.displayName)")
		}
	}
}
