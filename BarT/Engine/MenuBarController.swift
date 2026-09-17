import AppKit
import CoreGraphics
import Observation

/// Ties item enumeration, layout persistence and the drag engine together.
///
/// The single source of truth for the settings UI: it reads ``items`` and ``layout`` and calls
/// ``moveItem(_:to:)``; the controller takes care of the rest (saving, actually moving things
/// in the menu bar).
@MainActor
@Observable
final class MenuBarController {
	private(set) var items: [MenuBarItem] = []
	private(set) var layout: MenuBarLayout
	private(set) var lastError: String?

	/// `true` = the `hidden` section is temporarily revealed. `alwaysHidden` stays away while
	/// it is — that is what the second separator is for.
	private(set) var isRevealed = false

	/// Called on every change of the reveal state, including the automatic collapse — which
	/// would otherwise bypass the menu bar icon's symbol.
	///
	/// Deliberately not tied to ``isRevealed``: that field intentionally lags behind by the
	/// animation duration when collapsing, and the symbol change should not.
	var onRevealChanged: ((Bool) -> Void)?

	private let source = MenuBarItemSource()
	private let engine = DragHideEngine()
	private let store: LayoutStore

	private var hotKey: GlobalHotKey?

	/// `false` when ``GlobalHotKey/displayName`` is already taken by another app.
	private(set) var isHotKeyRegistered = false

	/// Every drag runs strictly one after another through this chain — never in parallel.
	/// Observed live: two simultaneous drags on the same item (a picker click and the
	/// reconcile loop met) destroyed each other (event taps on the same pid).
	private var operationChain: Task<Void, Never> = Task {}

	/// Brake against two neighbours being dragged back and forth forever (see ``OscillationGuard``).
	private var oscillation = OscillationGuard()

	/// BarT's own menu bar windows (icon, both separators) — these must never show up as
	/// manageable items. The separators come from the engine, the status icon registers itself
	/// from outside via ``excludeOwnWindow(_:)`` (see AppDelegate).
	private var excludedWindowIDs: Set<CGWindowID> = []

	/// Registers one more of our own windows (the primary status icon from AppDelegate, say)
	/// to be excluded from the managed list.
	func excludeOwnWindow(_ windowID: CGWindowID) {
		excludedWindowIDs.insert(windowID)
	}

	init(store: LayoutStore = LayoutStore()) {
		self.store = store
		self.layout = store.load()
	}

	func start() {
		// Collapsed is the base state: only then does the wide separator push everything to
		// its left out of the menu bar. Expanding happens temporarily via ``toggleReveal()``
		// and nowhere else.
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
		handleItemsChanged(source.snapshot())
		let hotKey = GlobalHotKey { [weak self] in self?.toggleReveal() }
		self.hotKey = hotKey
		isHotKeyRegistered = hotKey.isRegistered
		// Without this the 2 s poll never ran: the list then never refreshed by itself (think
		// of wrongly attributed names right after launch, before the accessibility permission
		// had been handed through) but only when some action (a picker click, a finished drag)
		// happened to pull a fresh snapshot.
		source.start()
	}

	/// Temporarily reveals or re-hides the `hidden` section — the gesture that gets you to a
	/// hidden item in the first place (a click on BarT's status item). `alwaysHidden`
	/// deliberately stays away; that is exactly what the section is for.
	///
	/// ponytail: no collapse on a timer — only the click beside it (see
	/// ``startOutsideClickMonitor()``).
	///
	/// - Parameter includingAlwaysHidden: additionally reveals `alwaysHidden` (⌥-click).
	///   Switching from either state to the other does not collapse but only changes the
	///   depth — only repeating the same gesture collapses.
	func toggleReveal(includingAlwaysHidden: Bool = false) {
		let target: DragHideEngine.Reveal = includingAlwaysHidden ? .all : .hidden
		if engine.reveal == target { collapse() } else { reveal(target) }
	}

	private func reveal(_ target: DragHideEngine.Reveal) {
		isRevealed = true
		engine.reveal = target
		startOutsideClickMonitor()
		onRevealChanged?(true)
	}

	private func collapse() {
		// Collapsing repeatedly is harmless, but would start another trailing ``Task`` each time.
		guard engine.reveal != .none else { return }
		engine.reveal = .none
		stopOutsideClickMonitor()
		onRevealChanged?(false)
		// ``isRevealed`` stays set until the animation ends: the separators change width with
		// an animation (~450 ms, see DragHideEngine), so every position measurement is an
		// intermediate state for that long. Reconciling against it would re-drag items that
		// are already filed correctly.
		Task {
			try? await Task.sleep(for: .milliseconds(500))
			// Revealed again in the meantime? Then the field belongs to the new state.
			guard self.engine.reveal == .none else { return }
			self.isRevealed = false
			// Catch up on what was suspended while revealed (newly appeared items, section
			// changes made in the settings).
			self.handleItemsChanged(self.source.snapshot())
		}
	}

	// MARK: Click outside

	private var outsideClickMonitor: Any?

	/// Collapses again as soon as the user clicks anywhere outside the menu bar.
	///
	/// Clicks *inside* the menu bar are exempt: revealing was the whole point, and collapsing
	/// right away would pull the item the user just clicked out from under the cursor. Our own
	/// app delivers nothing to a global monitor anyway — a click on BarT's own icon therefore
	/// runs exclusively through ``toggleReveal()``.
	private func startOutsideClickMonitor() {
		guard outsideClickMonitor == nil else { return }
		outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown]
		) { [weak self] _ in
			guard let self, !Self.isInMenuBar(NSEvent.mouseLocation) else { return }
			self.collapse()
		}
	}

	private func stopOutsideClickMonitor() {
		if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
		outsideClickMonitor = nil
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

	/// Moves an item to a different section, saves the layout and applies it.
	///
	/// Deliberately works off a fresh snapshot rather than the cached ``items`` list: that one
	/// is only updated on the poll (up to 2 s of lag), so right after one of our own drags it
	/// might still contain an item that no longer exists.
	func moveItem(_ key: String, to section: MenuBarLayout.Section) {
		layout.move(key, to: section)
		store.save(layout)
		// An explicit user decision — which gives even a previously stuck key its full drag
		// budget back (see ``OscillationGuard``).
		oscillation.release(key)
		if lastError != nil { lastError = nil }
		handleItemsChanged(source.snapshot())
	}

	private func handleItemsChanged(_ items: [MenuBarItem]) {
		self.items = items
		layout.reconcile(with: items.map(\.storageKey))
		store.save(layout)
		// No reconciling while revealed: the separators are in motion then (or have only just
		// come to rest), and whoever is using the revealed bar does not want automatic drags in
		// it. ``toggleReveal()`` catches up on the reconcile when collapsing.
		guard !isRevealed else { return }
		var pending = 0
		for item in items {
			guard let section = layout.section(of: item.storageKey) else { continue }
			if apply(item, to: section) { pending += 1 }
		}
		// Only when *every* item sits where its section wants it is the situation really
		// clean — and only then is resetting the brake safe, because by definition no further
		// drag follows from it.
		if pending == 0 { oscillation.reset() }
	}

	/// Brings a single item into the section the layout prescribes.
	/// No work if it is already there — every drag is visible (cursor, animation).
	///
	/// - Returns: `true` when the item is *not* where its section wants it — regardless of
	///   whether that actually causes a drag. The caller uses this to tell whether a reconcile
	///   pass has fully come to rest.
	@discardableResult
	private func apply(_ item: MenuBarItem, to section: MenuBarLayout.Section) -> Bool {
		guard engine.placement(of: item) != section else { return false }
		let key = item.storageKey
		// Do not even queue stuck keys: the operation would just wait, animate the separator
		// and end up doing nothing anyway.
		guard !oscillation.isStuck(key) else { return true }
		let previous = operationChain
		operationChain = Task {
			await previous.value

			// If the user has revealed in the meantime, the separators are in motion and every
			// measurement is an intermediate state (see ``handleItemsChanged(_:)``) — drop the
			// queued corrections, ``toggleReveal()`` catches up on them when collapsing.
			guard !self.isRevealed else { return }
			// Check again rather than trusting the snapshot captured at call time: by the time
			// this operation gets its turn, an earlier drag may already have corrected the
			// state (collateral displacement healed by reconcile, for instance).
			guard
				let current = self.items.first(where: { $0.storageKey == key }),
				self.engine.placement(of: current) != section
			else { return }
			// Last chance to bail out before real mouse events travel across the user's menu
			// bar: if this key has used up its budget, the item stays where it currently is.
			// Deliberately without a final re-enumeration — that would immediately trigger the
			// same correction again.
			guard self.oscillation.allowDrag(key) else {
				self.lastError = """
					“\(current.displayName)” could not be positioned reliably — most likely an \
					item sitting right next to it comes along on every move. It now stays where \
					it last ended up; selecting it in the list again starts a fresh attempt.
					"""
				return
			}

			// Moving back to `visible` drops at the *right* edge of the hidden separator — and
			// while collapsed that edge sits at the far end of the bar, which is the wrong
			// place. For the other two sections the left edge counts, and that one is always
			// correct.
			let needsRoom = section == .visible && self.engine.reveal == .none
			if needsRoom {
				self.engine.reveal = .hidden
				// The separator's width changes with an animation (~450 ms, see
				// DragHideEngine). Without the wait performDrag() reads an intermediate
				// position and the drop lands beside the target.
				try? await Task.sleep(for: .milliseconds(500))
			}
			// Only undo this if the user has not revealed in the meantime: a drag takes
			// seconds, and by then the separators belong to them, not to this operation.
			defer { if needsRoom, !self.isRevealed { self.engine.reveal = .none } }
			do {
				try await self.engine.move(current, to: section)
			} catch {
				self.lastError = error.localizedDescription
			}
			// Wait briefly before reading again: right after a drag the accessibility tree
			// (used for the owner lookup) lags behind the window geometry for a moment —
			// observed live, an *immediate* re-enumeration attributed exactly the windows that
			// had just moved (our own included!) to Control Center, because the AX position was
			// still the old one.
			try? await Task.sleep(for: .milliseconds(300))
			// Read and reconcile again instead of waiting up to 2 s for the next poll: this
			// heals a neighbouring item that came along by accident (collateral damage whose
			// section is still "visible") promptly rather than only at the poll, and makes sure
			// an immediately following counter-move sees fresh data.
			self.handleItemsChanged(self.source.snapshot())
		}
		return true
	}
}

// MARK: - Oscillation brake

/// Limits how often an item is automatically corrected before it is left alone.
///
/// With a single separator two physically adjacent items cannot be positioned independently:
/// a drag only guarantees the position of the *dragged* item relative to the separator, and the
/// neighbour slides along (a known limit of the technique, see ``DragHideEngine``). The
/// self-healing at the end of ``MenuBarController/apply(_:to:)`` then corrects the neighbour —
/// which displaces the first item again. Observed live with Stats' `Disk_mini` and `RAM_mini`:
/// endlessly, with real mouse events across the user's menu bar.
///
/// Hence: the drags actually performed are counted per key, and above the limit the key counts
/// as stuck and is no longer corrected automatically at all. It is reset *only* via ``reset()``
/// (everything sits correctly — from which, by definition, no further drag follows) or
/// ``release(_:)`` (an explicit user request). It is explicitly **not** reset when a single item
/// happens to sit correctly: that is precisely what keeps flipping while oscillating, and such a
/// reset would defeat the brake. This bounds the number of drags without user interaction from
/// above (limit × number of items).
struct OscillationGuard {
	/// Three attempts are enough for every benign case — an item normally needs one.
	static let limit = 3

	private var dragCounts: [String: Int] = [:]
	private var stuckKeys: Set<String> = []

	func isStuck(_ key: String) -> Bool { stuckKeys.contains(key) }

	/// Announces a drag that is about to happen.
	/// - Returns: `false` when the brake engages — do not drag then.
	mutating func allowDrag(_ key: String) -> Bool {
		guard !stuckKeys.contains(key) else { return false }
		let count = (dragCounts[key] ?? 0) + 1
		dragCounts[key] = count
		guard count > Self.limit else { return true }
		stuckKeys.insert(key)
		return false
	}

	/// An explicit user request for this key: full budget, even if it was stuck.
	mutating func release(_ key: String) {
		stuckKeys.remove(key)
		dragCounts[key] = nil
	}

	/// Everything sits — call in this state only.
	mutating func reset() {
		guard !dragCounts.isEmpty || !stuckKeys.isEmpty else { return }
		dragCounts.removeAll()
		stuckKeys.removeAll()
	}
}

// MARK: Self-test

extension OscillationGuard {
	/// Minimal self-test without a test framework; callable from the debug menu item.
	/// The oscillation cannot be triggered reproducibly live — here it can.
	@discardableResult
	static func runSelfTest() -> Bool {
		var failures: [String] = []
		func check(_ condition: Bool, _ message: String) {
			if !condition { failures.append(message) }
		}

		var normal = OscillationGuard()
		check(normal.allowDrag("a"), "the first drag is allowed")
		normal.reset()
		for step in 1...limit {
			check(normal.allowDrag("a"), "full budget again after reset() (step \(step))")
		}
		check(!normal.allowDrag("a"), "the budget is used up after \(limit) drags")
		check(normal.isStuck("a"), "an exhausted budget marks the key as stuck")

		// The actual case: two neighbours disturb each other in turn, a reconcile pass never
		// comes to rest — so nothing is ever reset either.
		var pingPong = OscillationGuard()
		var drags = 0
		for _ in 0..<100 {
			for key in ["disk", "ram"] where pingPong.allowDrag(key) { drags += 1 }
		}
		check(drags == 2 * limit, "oscillation ends after \(2 * limit) drags, got \(drags)")
		check(
			pingPong.isStuck("disk") && pingPong.isStuck("ram"),
			"both neighbours end up stuck"
		)

		pingPong.release("disk")
		check(!pingPong.isStuck("disk"), "release() unsticks the key again")
		check(pingPong.allowDrag("disk"), "release() grants a fresh attempt")
		check(pingPong.isStuck("ram"), "release() only affects the named key")

		if failures.isEmpty {
			print("[BarT] OscillationGuard self-test: all checks passed")
		} else {
			for failure in failures {
				print("[BarT] OscillationGuard self-test FAILED: \(failure)")
			}
		}
		assert(failures.isEmpty, "OscillationGuard self-test failed")
		return failures.isEmpty
	}
}
