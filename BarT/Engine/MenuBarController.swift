import AppKit
import CoreGraphics
import Observation

/// Ties item enumeration and the separators together.
///
/// The single source of truth for the settings UI: it reads ``items`` and ``section(of:)``.
/// Since BT-15 the controller changes nothing about other apps' items — arranging them is the
/// user's own ⌘-drag. What is left here is the reveal state and the list.
@MainActor
@Observable
final class MenuBarController {
	private(set) var items: [MenuBarItem] = []

	/// Section per item, measured at the moment the list was read. Keyed by window ID because
	/// that is the only identity an item has now.
	private(set) var sections: [CGWindowID: MenuBarSection] = [:]

	private(set) var lastError: String?

	/// `true` = the `hidden` section is temporarily revealed. `alwaysHidden` stays away while
	/// it is — that is what the second separator is for.
	private(set) var isRevealed = false

	/// Called on every change of the reveal state, including the automatic collapse — which
	/// would otherwise bypass the menu bar icon's symbol.
	var onRevealChanged: ((Bool) -> Void)?

	private let source = MenuBarItemSource()
	private let engine = SeparatorEngine()

	private var hotKey: GlobalHotKey?

	/// `false` when ``GlobalHotKey/displayName`` is already taken by another app.
	private(set) var isHotKeyRegistered = false

	/// BarT's own menu bar windows (icon, both separators) — these must never show up in the
	/// list. The separators come from the engine, the status icon registers itself from outside
	/// via ``excludeOwnWindow(_:)`` (see AppDelegate).
	private var excludedWindowIDs: Set<CGWindowID> = []

	/// Registers one more of our own windows to be excluded from the list.
	func excludeOwnWindow(_ windowID: CGWindowID) {
		excludedWindowIDs.insert(windowID)
	}

	func section(of item: MenuBarItem) -> MenuBarSection {
		sections[item.windowID] ?? .visible
	}

	func start() async {
		// Collapsed is the base state: only then does the wide separator push everything to
		// its left out of the menu bar.
		engine.reveal = .none
		// Ask for the separator IDs fresh on every enumeration instead of adding them later:
		// otherwise they slip through as items between creation and registration.
		source.excludedWindowIDs = { [weak self] in
			guard let self else { return [] }
			return self.excludedWindowIDs.union(self.engine.separatorWindowIDs)
		}
		source.onChange = { [weak self] items in
			self?.handleItemsChanged(items)
		}

		// Without the separators there are no sections at all, so this happens at startup —
		// until BT-15 the first drag created them lazily, and there are no drags any more.
		do {
			try await engine.prepareSeparators()
		} catch {
			lastError = error.localizedDescription
		}

		handleItemsChanged(source.snapshot())
		let hotKey = GlobalHotKey { [weak self] in self?.toggleReveal() }
		self.hotKey = hotKey
		isHotKeyRegistered = hotKey.isRegistered
		source.start()
	}

	/// Temporarily reveals or re-hides the `hidden` section — the gesture that gets you to a
	/// hidden item in the first place (a click on BarT's status item). `alwaysHidden`
	/// deliberately stays away; that is exactly what the section is for.
	///
	/// - Parameter includingAlwaysHidden: additionally reveals `alwaysHidden` (⌥-click).
	///   Switching from either state to the other does not collapse but only changes the
	///   depth — only repeating the same gesture collapses.
	func toggleReveal(includingAlwaysHidden: Bool = false) {
		let target: SeparatorEngine.Reveal = includingAlwaysHidden ? .all : .hidden
		if engine.reveal == target { collapse() } else { reveal(target) }
	}

	private func reveal(_ target: SeparatorEngine.Reveal) {
		isRevealed = true
		engine.reveal = target
		startOutsideClickMonitor()
		startAutoCollapse()
		onRevealChanged?(true)
	}

	private func collapse() {
		// Collapsing repeatedly is harmless, but would start another trailing ``Task`` each time.
		guard engine.reveal != .none else { return }
		engine.reveal = .none
		stopOutsideClickMonitor()
		autoCollapse?.cancel()
		onRevealChanged?(false)
		// ``isRevealed`` stays set until the animation ends: the separators change width with
		// an animation (~450 ms), so every position measurement is an intermediate state for
		// that long.
		Task {
			try? await Task.sleep(for: .milliseconds(500))
			// Revealed again in the meantime? Then the field belongs to the new state.
			guard self.engine.reveal == .none else { return }
			self.isRevealed = false
			self.handleItemsChanged(self.source.snapshot())
		}
	}

	// MARK: Click outside

	private var outsideClickMonitor: Any?

	/// Collapses again as soon as the user clicks anywhere outside the menu bar.
	///
	/// Clicks *inside* the menu bar are exempt: revealing was the whole point, and collapsing
	/// right away would pull the item the user just clicked out from under the cursor — or
	/// interrupt the ⌘-drag they are using to arrange things. Our own app delivers nothing to a
	/// global monitor anyway, so a click on BarT's own icon runs exclusively through
	/// ``toggleReveal()``.
	private func startOutsideClickMonitor() {
		guard outsideClickMonitor == nil else { return }
		outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown]
		) { [weak self] _ in
			guard let self else { return }
			// A click *inside* the menu bar is the user working with the revealed items — that
			// renews the deadline rather than ending it.
			guard !Self.isInMenuBar(NSEvent.mouseLocation) else {
				self.startAutoCollapse()
				return
			}
			self.collapse()
		}
	}

	private func stopOutsideClickMonitor() {
		if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
		outsideClickMonitor = nil
	}

	// MARK: Auto-collapse

	/// How long the bar stays revealed without interaction.
	///
	/// ponytail: fixed rather than configurable — it is one more setting for a difference almost
	/// nobody wants to choose. Raise it here if practice says 15 s is too brisk.
	private static let autoCollapseDelay: Duration = .seconds(15)

	private var autoCollapse: Task<Void, Never>?

	/// Starts the deadline over. Called on every reveal and on every click inside the menu bar,
	/// so the timer measures inactivity, not the time since revealing.
	///
	/// A `Task` rather than a `Timer`: cancelling is exact, and ``collapse()`` refuses to run
	/// twice anyway.
	private func startAutoCollapse() {
		autoCollapse?.cancel()
		autoCollapse = Task { [weak self] in
			try? await Task.sleep(for: Self.autoCollapseDelay)
			guard !Task.isCancelled else { return }
			self?.collapse()
		}
	}

	/// `visibleFrame` ends at the top exactly below the menu bar — whatever is above it is the
	/// menu bar.
	private static func isInMenuBar(_ location: NSPoint) -> Bool {
		guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
			return false
		}
		return location.y > screen.visibleFrame.maxY
	}

	/// Debug: checks what can only be checked on a running system — the order of the
	/// separators, and whether the hotkey could be registered at all.
	func runStartupSelfTest() async {
		await engine.runSeparatorSelfTest()
		print(
			"[BarT] Hotkey \(GlobalHotKey.displayName): "
				+ (isHotKeyRegistered ? "registered" : "FAILED — already taken")
		)
	}

	private func handleItemsChanged(_ items: [MenuBarItem]) {
		self.items = items
		// Measure every item in the same pass: the sections are only comparable when they were
		// read against the same separator positions.
		sections = items.reduce(into: [:]) { result, item in
			result[item.windowID] = engine.placement(of: item) ?? .visible
		}
	}
}
