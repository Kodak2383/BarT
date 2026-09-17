import AppKit
import CoreGraphics
import OSLog

/// Hides and shows other apps' menu bar items via a simulated Cmd-drag.
///
/// ## How it works
/// macOS natively rearranges status items on Cmd-drag. The engine creates two status items of
/// its own to act as separators and pushes target items next to them with a synthetic
/// Cmd-drag. Status items are laid out from the right edge of the screen leftwards: growing a
/// separator's width pushes everything to its *left* out of the visible area.
///
/// That yields three sections, from right to left:
///
///     [ visible ] [hidden separator] [ hidden ] [alwaysHidden separator] [ alwaysHidden ]
///
/// Which sections are visible is decided by ``reveal``. Where an item actually sits is
/// answered by ``placement(of:)`` — not by `isOnScreen`.
///
/// ## Known limits (not fixable, only mitigable)
/// - There is no official API for this. The technique relies on private CGS calls (see
///   `Bridging.swift`) and on macOS allowing Cmd-drag on status items.
/// - The drag runs on real mouse events. The cursor is hidden for the duration and restored
///   afterwards, but a visible twitch is possible.
/// - If the user moves the mouse themselves meanwhile, or holds modifiers down, the drag fails
///   or moves the wrong item.
/// - If the target item's owner process is unresponsive it accepts the mouseDown but never the
///   mouseUp — the drag state would hang. Responsiveness is therefore checked beforehand and a
///   mouseUp is pushed after the fact in every case.
/// - Items macOS pins itself (clock, Control Center) cannot be moved; the drag then runs
///   through without effect and verification fails.
///
/// This class starts nothing on its own. The separators only come into being on the first call
/// to ``move(_:to:)``.
@MainActor
final class DragHideEngine {
	enum DragError: LocalizedError {
		case notTrusted
		case ownerUnresponsive(String)
		case separatorUnavailable
		case separatorOrder
		case itemGone
		case eventSourceUnavailable
		case eventCreationFailed
		case eventDeliveryTimeout
		case verificationFailed(String)

		var errorDescription: String? {
			switch self {
			case .notTrusted:
				"No accessibility permission."
			case .ownerUnresponsive(let name):
				"The app “\(name)” is not responding."
			case .separatorUnavailable:
				"The separator item could not be placed in the menu bar."
			case .separatorOrder:
				"The two separators sit in the wrong order in the menu bar."
			case .itemGone:
				"The item no longer exists."
			case .eventSourceUnavailable:
				"Could not create a CGEventSource."
			case .eventCreationFailed:
				"Could not create a mouse event."
			case .eventDeliveryTimeout:
				"The mouse event was not delivered in time."
			case .verificationFailed(let name):
				"“\(name)” did not end up at the expected position after several attempts."
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
		/// in with an animation (measured at ~450 ms, from 12×10 to 40×30 pt). A drop onto an
		/// intermediate state lands in the wrong place.
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

	private static let log = Logger(subsystem: "de.andreduhme.BarT", category: "DragHideEngine")

	private static let maxAttempts = 3
	/// How long to wait for confirmation at the session tap (value taken from Ice).
	private static let scrombleTimeoutMilliseconds = 50
	/// Tolerance, because macOS realigns the items by sub-pixels after a drop.
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

	/// Window IDs of our own separators, as far as they exist — for exclusion from the managed
	/// item list. Deliberately the window ID, not PID/bundle ID: in exactly the race where the
	/// owner lookup misattributes our own windows to Control Center, the window ID stays
	/// correct.
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
	func placement(of item: MenuBarItem) -> MenuBarLayout.Section? {
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
	/// The order is crucial: the `alwaysHidden` separator has to sit left of the `hidden`
	/// separator, otherwise every assignment is inverted. macOS places a new status item left
	/// of the existing ones — hence strictly one after another, each fully realized before the
	/// next joins: otherwise the next one's window ID diff would pick up its predecessor's
	/// window, which is only just appearing. That placement is guaranteed nowhere, so it is
	/// verified at the end.
	private func prepareSeparators() async throws {
		if hiddenSeparator != nil, alwaysHiddenSeparator != nil { return }
		removeSeparators()

		let hidden = Separator(isCollapsed: hiddenSeparatorCollapses)
		hiddenSeparator = hidden
		do {
			guard await hidden.realizedWindowID() != nil else {
				throw DragError.separatorUnavailable
			}
			let alwaysHidden = Separator(isCollapsed: alwaysHiddenSeparatorCollapses)
			alwaysHiddenSeparator = alwaysHidden
			guard
				await alwaysHidden.realizedWindowID() != nil,
				let hiddenFrame = hidden.frame,
				let alwaysHiddenFrame = alwaysHidden.frame
			else { throw DragError.separatorUnavailable }
			guard alwaysHiddenFrame.maxX <= hiddenFrame.minX + Self.tolerance else {
				throw DragError.separatorOrder
			}
		} catch {
			removeSeparators()
			throw error
		}
	}

	/// Where to drop so the item ends up in the requested section — together with the
	/// separator window the drop addresses.
	private func dropTarget(
		for section: MenuBarLayout.Section
	) -> (point: CGPoint, windowID: CGWindowID)? {
		let separator = switch section {
		case .visible, .hidden: hiddenSeparator
		case .alwaysHidden: alwaysHiddenSeparator
		}
		guard let windowID = separator?.windowID, let frame = separator?.frame else { return nil }
		let x = section == .visible ? frame.maxX : frame.minX
		return (CGPoint(x: x, y: frame.midY), windowID)
	}

	// MARK: Drag

	func move(_ item: MenuBarItem, to section: MenuBarLayout.Section) async throws {
		guard AccessibilityPermission.isTrusted else { throw DragError.notTrusted }
		guard CGSBridge.frame(for: item.windowID) != nil else { throw DragError.itemGone }
		guard !CGSBridge.isUnresponsive(pid: item.ownerPID) else {
			throw DragError.ownerUnresponsive(item.displayName)
		}

		// Create the separators and wait for them to finish laying out *before* reading their
		// geometry.
		try await prepareSeparators()

		// Save the cursor and release it again in every case — even if the drag throws.
		let savedCursor = CGEvent(source: nil)?.location
		NSCursor.hide()
		defer {
			if let savedCursor {
				CGWarpMouseCursorPosition(savedCursor)
			}
			CGAssociateMouseAndMouseCursorPosition(1)
			NSCursor.unhide()
		}

		for attempt in 1...Self.maxAttempts {
			do {
				try await performDrag(item, to: section)
			} catch {
				// A failed attempt does not end the series — the next one may get through.
				// Only if all of them fail does ``verificationFailed`` throw.
				Self.log.warning(
					"Attempt \(attempt) for \(item.displayName, privacy: .public) threw: \(error.localizedDescription, privacy: .public)"
				)
			}

			if await waitUntilPositioned(item, in: section) {
				Self.log.info("Moved \(item.displayName, privacy: .public) (attempt \(attempt))")
				return
			}
			Self.log.warning("Attempt \(attempt) for \(item.displayName, privacy: .public) failed")
			// ponytail: a fixed delay instead of Ice's "wakeUpItem" wake-up click. If practice
			// shows that dormant processes regularly swallow the first drag, insert a
			// Cmd-down/up on the spot here.
			try? await Task.sleep(for: .milliseconds(80))
		}

		// Safety net: in case a mouseDown got through without an effective mouseUp, definitely
		// let go here so the target process does not stay in the drag state.
		releaseDrag(item)
		throw DragError.verificationFailed(item.displayName)
	}

	private func performDrag(_ item: MenuBarItem, to section: MenuBarLayout.Section) async throws {
		guard
			let itemFrame = CGSBridge.frame(for: item.windowID),
			let target = dropTarget(for: section)
		else { throw DragError.itemGone }

		guard let source = CGEventSource(stateID: .hidSystemState) else {
			throw DragError.eventSourceUnavailable
		}
		permitAllEvents()

		// The start point deliberately sits far outside every screen: which item gets dragged
		// is decided by the event's windowID fields, not by the cursor position. That way no
		// other item ends up under the simulated pointer. (Technique from Ice, MIT.)
		let startPoint = CGPoint(x: 20_000, y: 20_000)

		guard
			let mouseDown = CGEvent.menuBarItemEvent(
				type: .leftMouseDown, flags: .maskCommand, location: startPoint,
				targetWindowID: item.windowID, pid: item.ownerPID, source: source
			),
			let mouseUp = CGEvent.menuBarItemEvent(
				type: .leftMouseUp, flags: [], location: target.point,
				targetWindowID: target.windowID, pid: item.ownerPID, source: source
			)
		else { throw DragError.eventCreationFailed }

		try await scromble(mouseDown, pid: item.ownerPID)
		// Deliberately no bailing out between down and up: a mouseDown without a mouseUp
		// leaves a hanging drag in the target process.
		// `false` means the target process did not accept the drag — the single most telling
		// value when tracking down failures, which is why it stays as a debug log.
		let moved = await waitForFrameChange(of: item.windowID, from: itemFrame)
		Self.log.debug(
			"\(item.displayName, privacy: .public) picked up: \(moved), target \(target.point.x)"
		)
		do {
			try await scromble(mouseUp, pid: item.ownerPID)
		} catch {
			releaseDrag(item)
			throw error
		}
		try? await Task.sleep(for: .milliseconds(30))
	}

	/// Delivers a mouse event in a way that makes the target process accept it as a real drag.
	///
	/// A plain `postToPid` is not enough — verified live: the drag ran through without error,
	/// but the item stayed exactly where it was. The event then only lands in the target app's
	/// event queue; the window system never sees a drag begin, so the menu bar's rearranging
	/// machinery never starts in the first place.
	///
	/// The detour: post a null event to the target process and, in the tap belonging to it,
	/// forward the real event to the *session* tap. Only once it has been observed there — so
	/// once the system has seen it — does it go to the process via `postToPid`. Technique
	/// ("scromble") taken one to one from Ice (MIT), `MenuBarItemManager.scrombleEvent`.
	private func scromble(_ event: CGEvent, pid: pid_t) async throws {
		guard let nullEvent = CGEvent(source: nil) else { throw DragError.eventCreationFailed }
		let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
		nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)
		let userData = event.getIntegerValueField(.eventSourceUserData)

		var taps: [EventTap] = []
		defer { taps.forEach { $0.invalidate() } }

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			var isResumed = false
			func finish(_ result: Result<Void, Error>) {
				guard !isResumed else { return }
				isResumed = true
				continuation.resume(with: result)
			}

			guard
				let pidTap = EventTap(
					options: .defaultTap, location: .pid(pid), types: [nullEvent.type],
					handler: { tap, _, received in
						guard received.getIntegerValueField(.eventSourceUserData) == nullUserData else {
							return received
						}
						tap.disable()
						event.post(tap: .cgSessionEventTap)
						return nil // The null event itself must not reach the process.
					}
				),
				let sessionTap = EventTap(
					options: .listenOnly, location: .sessionEventTap, types: [event.type],
					handler: { tap, _, received in
						guard
							tap.isEnabled,
							received.getIntegerValueField(.eventSourceUserData) == userData
						else { return received }
						tap.disable()
						event.postToPid(pid)
						finish(.success(()))
						return received
					}
				)
			else {
				finish(.failure(DragError.eventCreationFailed))
				return
			}

			taps = [pidTap, sessionTap]
			pidTap.enable()
			sessionTap.enable()

			Task {
				try? await Task.sleep(for: .milliseconds(Self.scrombleTimeoutMilliseconds))
				finish(.failure(DragError.eventDeliveryTimeout))
			}

			nullEvent.postToPid(pid)
		}
	}

	/// After the drop macOS rearranges the bar with an animation — item *and* separators are
	/// still travelling while it does. A single comparison right after the mouseUp therefore
	/// reliably catches an intermediate state (measured live: frames overlapped by 18 pt, the
	/// separator width fluctuated between 38 and 41 pt). So keep checking until things snap
	/// into place. Two consecutive hits are required rather than a single one: observed live,
	/// a single hit in the middle of Apple's own rearranging animation waved an intermediate
	/// position through as final — the bar then rearranged once more and the item ended up
	/// somewhere else, without an error being thrown here.
	private func waitUntilPositioned(
		_ item: MenuBarItem, in section: MenuBarLayout.Section
	) async -> Bool {
		var consecutiveHits = 0
		for attempt in 0..<40 {
			if attempt > 0 { try? await Task.sleep(for: .milliseconds(25)) }
			// The same measurement the controller uses to read the actual state — what passes
			// as done here cannot immediately count as wrong there.
			if placement(of: item) == section {
				consecutiveHits += 1
				if consecutiveHits >= 2 { return true }
			} else {
				consecutiveHits = 0
			}
		}
		return false
	}

	/// Posts a mouseUp on the item itself, to resolve a drag state that may be hanging in the
	/// target process.
	private func releaseDrag(_ item: MenuBarItem) {
		guard
			let frame = CGSBridge.frame(for: item.windowID),
			let source = CGEventSource(stateID: .hidSystemState),
			let mouseUp = CGEvent.menuBarItemEvent(
				type: .leftMouseUp, flags: [],
				location: CGPoint(x: frame.midX, y: frame.midY),
				targetWindowID: item.windowID, pid: item.ownerPID, source: source
			)
		else { return }
		mouseUp.postToPid(item.ownerPID)
	}

	private func waitForFrameChange(of windowID: CGWindowID, from initialFrame: CGRect) async -> Bool {
		for _ in 0..<12 {
			try? await Task.sleep(for: .milliseconds(5))
			guard let frame = CGSBridge.frame(for: windowID) else { return false }
			if frame != initialFrame { return true }
		}
		return false
	}

	/// Without this the window system discards the synthetic events as "suppressed" whenever
	/// real input happened shortly before.
	private func permitAllEvents() {
		guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
		for state in [
			CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag,
			CGEventSuppressionState.eventSuppressionStateSuppressionInterval,
		] {
			source.setLocalEventsFilterDuringSuppressionState(
				[.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
				state: state
			)
		}
		source.localEventsSuppressionInterval = 0
	}
}

// MARK: - Self-test

extension DragHideEngine {
	/// Creates the separators (unless that already happened) and checks the one assumption that
	/// cannot be derived from the code: that macOS places a new status item *left* of the
	/// existing ones. If that does not hold, the meaning of both sections is inverted.
	///
	/// Callable from the debug menu item; there is no other way to follow this live, because in
	/// the normal state both separators sit off screen.
	@discardableResult
	func runSeparatorSelfTest() async -> Bool {
		do {
			// Already throws on a swapped order (``DragError/separatorOrder``).
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

// MARK: - CGEvent construction

private extension CGEventField {
	/// Undocumented field for an event's window ID. Raw value taken from Ice (MIT),
	/// Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift @ 11edd39115f3.
	static let windowID = CGEventField(rawValue: 0x33)!
}

private extension CGEvent {
	/// Creates a mouse event addressing one particular menu bar item.
	///
	/// The three windowID fields are what matters: they tell the target process which of its
	/// status item windows is meant — regardless of where the pointer sits. Field selection
	/// taken from Ice (MIT), `CGEvent.menuBarItemEvent`.
	static func menuBarItemEvent(
		type: CGEventType,
		flags: CGEventFlags,
		location: CGPoint,
		targetWindowID: CGWindowID,
		pid: pid_t,
		source: CGEventSource
	) -> CGEvent? {
		guard let event = CGEvent(
			mouseEventSource: source,
			mouseType: type,
			mouseCursorPosition: location,
			mouseButton: .left
		) else { return nil }

		event.flags = flags

		let windowID = Int64(targetWindowID)
		event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
		event.setIntegerValueField(
			.eventSourceUserData,
			value: Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
		)
		event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
		event.setIntegerValueField(
			.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID
		)
		event.setIntegerValueField(.windowID, value: windowID)

		return event
	}
}
