import AppKit
import CoreGraphics

/// Which of the three areas of the menu bar an item sits in.
///
/// Not a stored assignment — the section of an item is *measured*, from its position relative to
/// the separators. The user arranges items themselves with the ⌘-drag macOS provides, and macOS
/// remembers the arrangement.
enum MenuBarSection: String, CaseIterable, Sendable {
	case visible
	case hidden
	case alwaysHidden
}

/// Splits the menu bar into three areas with two status items of BarT's own, and collapses or
/// expands them.
///
/// ## How it works
/// Status items are laid out from the right edge of the screen leftwards, so growing an item's
/// width pushes everything to its *left* out of the visible area. Two such items yield three
/// areas, from right to left:
///
///     [ visible ] [hidden separator] [ hidden ] [alwaysHidden separator] [ alwaysHidden ]
///
/// How far the bar is expanded is decided by ``reveal``. Where an item actually sits is answered
/// by ``placement(of:)`` — not by `isOnScreen`, which says something different.
///
/// This mechanism is BarT's own; it is the same approach Hidden Bar, Dozer and Vanilla take. The
/// engine that used to *move* other apps' items into these areas with a simulated ⌘-drag was
/// removed in BT-15 — it came from Ice (GPL-3.0), and arranging is the user's job now.
///
/// ## Known limits
/// - Private CGS calls (see `Bridging.swift`) are used to find the separators' window IDs. There
///   is no official API for any of this.
/// - Only the main screen is managed.
@MainActor
final class SeparatorEngine {
	enum SeparatorError: LocalizedError {
		case separatorUnavailable
		case separatorOrder

		var errorDescription: String? {
			switch self {
			case .separatorUnavailable:
				"The separator item could not be placed in the menu bar."
			case .separatorOrder:
				"The two separators sit in the wrong order in the menu bar."
			}
		}
	}

	/// A status item of our own that acts as the boundary between two sections.
	@MainActor
	private final class Separator {
		/// Width while collapsed — wide enough to push everything to its left out of the menu bar.
		private static let collapsedLength: CGFloat = 10_000
		private static let expandedLength: CGFloat = 24

		private let item: NSStatusItem
		/// Menu bar windows that already existed before *this* one was created — the basis for
		/// the diff in ``realizedWindowID()``.
		private let windowIDsBefore: Set<CGWindowID>
		private var cachedWindowID: CGWindowID?

		/// `true` = everything to the left of this separator is pushed out of the visible area.
		var isCollapsed: Bool {
			didSet { item.length = isCollapsed ? Self.collapsedLength : Self.expandedLength }
		}

		init(isCollapsed: Bool) {
			self.isCollapsed = isCollapsed
			windowIDsBefore = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: false))
			item = NSStatusBar.system.statusItem(
				withLength: isCollapsed ? Self.collapsedLength : Self.expandedLength
			)
			item.button?.image = NSImage(
				systemSymbolName: "chevron.compact.left",
				accessibilityDescription: "BarT separator"
			)
			item.button?.image?.isTemplate = true
		}

		var windowID: CGWindowID? { cachedWindowID }
		var frame: CGRect? { cachedWindowID.flatMap(CGSBridge.frame(for:)) }

		/// The CGWindowID, as soon as the separator sits fully laid out in the menu bar.
		///
		/// `button.window.windowNumber` has been useless for this since macOS 26: status items
		/// are hosted out of process, and the local `NSWindow` constantly reports
		/// `0x2_0000_0000` (measured live). The real ID is instead the menu bar window that
		/// newly appears in the CGS list after creation.
		///
		/// What is awaited is a *stable* frame rather than a fixed sleep: the separator slides
		/// in with an animation (measured at ~450 ms, from 12×10 to 40×30 pt).
		func realizedWindowID() async -> CGWindowID? {
			if let cachedWindowID { return cachedWindowID }
			var lastFrame: CGRect?
			for attempt in 0..<40 {
				if attempt > 0 { try? await Task.sleep(for: .milliseconds(25)) }
				guard
					let id = CGSBridge.menuBarWindowIDs(onScreenOnly: false)
						.first(where: { !windowIDsBefore.contains($0) }),
					let frame = CGSBridge.frame(for: id)
				else { continue }
				if frame == lastFrame {
					cachedWindowID = id
					return id
				}
				lastFrame = frame
			}
			return nil
		}

		func remove() {
			NSStatusBar.system.removeStatusItem(item)
		}
	}

	/// Tolerance, because macOS realigns the items by sub-pixels.
	private static let tolerance: CGFloat = 1

	/// Boundary between `visible` (to its right) and `hidden` (to its left).
	private var hiddenSeparator: Separator?
	/// Boundary between `hidden` (to its right) and `alwaysHidden` (to its left). Always sits
	/// left of the ``hiddenSeparator`` — ensured in ``prepareSeparators()``.
	private var alwaysHiddenSeparator: Separator?

	/// How far the bar is currently expanded.
	enum Reveal {
		/// `visible` only — the normal state.
		case none
		/// Plus `hidden`.
		case hidden
		/// Everything, `alwaysHidden` included.
		case all
	}

	/// The two separators are never wide at the same time: it is enough for whichever one is
	/// further right to push everything left of it out. Two 10,000 pt items side by side would
	/// shift the bar by 20,000 pt for no reason.
	var reveal: Reveal = .none {
		didSet {
			hiddenSeparator?.isCollapsed = hiddenSeparatorCollapses
			alwaysHiddenSeparator?.isCollapsed = alwaysHiddenSeparatorCollapses
		}
	}

	private var hiddenSeparatorCollapses: Bool { reveal == .none }
	private var alwaysHiddenSeparatorCollapses: Bool { reveal == .hidden }

	/// Window IDs of our own separators, as far as they exist — for exclusion from the item
	/// list. Deliberately the window ID, not PID/bundle ID: all status items report the same
	/// hosting process, so a PID would exclude half the bar.
	var separatorWindowIDs: Set<CGWindowID> {
		Set([hiddenSeparator?.windowID, alwaysHiddenSeparator?.windowID].compactMap { $0 })
	}

	/// Where the item *actually* sits, measured against the separators.
	///
	/// `isOnScreen` is no good for this: `hidden` and `alwaysHidden` are both invisible as long
	/// as nothing is revealed, and conversely, while revealed, hidden things are visible too.
	/// The position relative to the separators, by contrast, is correct in every state.
	///
	/// - Returns: `nil` when the window has vanished.
	func placement(of item: MenuBarItem) -> MenuBarSection? {
		guard let frame = CGSBridge.frame(for: item.windowID) else { return nil }
		// Without separators there is nothing for anything to be to the left of.
		guard
			let hiddenFrame = hiddenSeparator?.frame,
			frame.maxX <= hiddenFrame.minX + Self.tolerance
		else { return .visible }
		guard
			let alwaysHiddenFrame = alwaysHiddenSeparator?.frame,
			frame.maxX <= alwaysHiddenFrame.minX + Self.tolerance
		else { return .hidden }
		return .alwaysHidden
	}

	func removeSeparators() {
		hiddenSeparator?.remove()
		alwaysHiddenSeparator?.remove()
		hiddenSeparator = nil
		alwaysHiddenSeparator = nil
	}

	// MARK: Separators

	/// Creates both separators (if needed) and waits until they sit stably in the bar.
	///
	/// Called at startup — without the separators there are no sections at all. (Until BT-15 they
	/// were created lazily by the first drag; there are no drags any more.)
	///
	/// The order is crucial: the `alwaysHidden` separator has to sit left of the `hidden`
	/// separator, otherwise the meaning of both sections is inverted. macOS places a new status
	/// item left of the existing ones — hence strictly one after another, each fully realized
	/// before the next joins: otherwise the next one's window ID diff would pick up its
	/// predecessor's window, which is only just appearing. That placement is guaranteed nowhere,
	/// so it is verified at the end.
	func prepareSeparators() async throws {
		if hiddenSeparator != nil, alwaysHiddenSeparator != nil { return }
		removeSeparators()

		let hidden = Separator(isCollapsed: hiddenSeparatorCollapses)
		hiddenSeparator = hidden
		do {
			guard await hidden.realizedWindowID() != nil else {
				throw SeparatorError.separatorUnavailable
			}
			let alwaysHidden = Separator(isCollapsed: alwaysHiddenSeparatorCollapses)
			alwaysHiddenSeparator = alwaysHidden
			guard
				await alwaysHidden.realizedWindowID() != nil,
				let hiddenFrame = hidden.frame,
				let alwaysHiddenFrame = alwaysHidden.frame
			else { throw SeparatorError.separatorUnavailable }
			guard alwaysHiddenFrame.maxX <= hiddenFrame.minX + Self.tolerance else {
				throw SeparatorError.separatorOrder
			}
		} catch {
			removeSeparators()
			throw error
		}
	}
}

// MARK: - Self-test

extension SeparatorEngine {
	/// Creates the separators (unless that already happened) and checks the one assumption that
	/// cannot be derived from the code: that macOS places a new status item *left* of the
	/// existing ones. If that does not hold, the meaning of both sections is inverted.
	///
	/// Callable from the debug menu item; there is no other way to follow this live, because in
	/// the normal state both separators sit off screen.
	@discardableResult
	func runSeparatorSelfTest() async -> Bool {
		do {
			// Already throws on a swapped order (``SeparatorError/separatorOrder``).
			try await prepareSeparators()
		} catch {
			print("[BarT] Separator self-test FAILED: \(error.localizedDescription)")
			return false
		}
		guard
			let hidden = hiddenSeparator?.frame,
			let alwaysHidden = alwaysHiddenSeparator?.frame
		else {
			print("[BarT] Separator self-test FAILED: no frame available")
			return false
		}
		print(
			String(
				format: "[BarT]   hidden separator        x=%9.1f…%9.1f",
				hidden.minX, hidden.maxX
			)
		)
		print(
			String(
				format: "[BarT]   alwaysHidden separator  x=%9.1f…%9.1f",
				alwaysHidden.minX, alwaysHidden.maxX
			)
		)
		print("[BarT] Separator self-test: order is correct (alwaysHidden sits on the left)")
		return true
	}
}
