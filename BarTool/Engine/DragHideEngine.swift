import AppKit
import CoreGraphics
import OSLog

/// Versteckt und zeigt fremde Menüleisten-Items über einen simulierten Cmd-Drag.
///
/// ## Funktionsprinzip
/// macOS ordnet Status-Items nativ per Cmd+Drag um. Die Engine erzeugt zwei eigene
/// Trenner-Status-Items und schiebt Ziel-Items per synthetischem Cmd-Drag daneben.
/// Status-Items werden vom rechten Bildschirmrand nach links gelayoutet: vergrößert man die
/// Breite eines Trenners, rutscht alles *links* von ihm aus dem sichtbaren Bereich.
///
/// Daraus ergeben sich drei Sektionen, von rechts nach links:
///
///     [ visible ] [hidden-Trenner] [ hidden ] [alwaysHidden-Trenner] [ alwaysHidden ]
///
/// Welche Sektionen sichtbar sind, entscheidet ``reveal``. Wo ein Item wirklich steht, sagt
/// ``placement(of:)`` — nicht `isOnScreen`.
///
/// ## Bekannte Grenzen (nicht behebbar, nur abmilderbar)
/// - Es gibt keine offizielle API dafür. Die Technik beruht auf privaten CGS-Aufrufen
///   (siehe `Bridging.swift`) und darauf, dass macOS Cmd-Drag auf Status-Items erlaubt.
/// - Der Drag läuft über echte Maus-Events. Der Cursor wird währenddessen ausgeblendet und
///   danach zurückgesetzt, ein sichtbares Zucken ist aber möglich.
/// - Bewegt der Nutzer währenddessen selbst die Maus oder hält er Modifier gedrückt,
///   schlägt der Drag fehl oder verschiebt das falsche Item.
/// - Reagiert der Owner-Prozess des Ziel-Items nicht, nimmt er den mouseDown an, aber nie
///   den mouseUp — der Drag-Zustand bliebe hängen. Deshalb wird die Responsivität vorher
///   geprüft und am Ende in jedem Fall ein mouseUp nachgeschoben.
/// - Items, die macOS selbst fixiert (Uhr, Kontrollzentrum), lassen sich nicht bewegen;
///   der Drag läuft dann erfolglos durch und die Verifikation schlägt fehl.
///
/// Diese Klasse startet nichts von selbst. Die Trenner entstehen erst beim ersten Aufruf von
/// ``move(_:to:)``.
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
				"Keine Bedienungshilfen-Berechtigung."
			case .ownerUnresponsive(let name):
				"Die App „\(name)“ reagiert nicht."
			case .separatorUnavailable:
				"Trenner-Item konnte nicht in der Menüleiste platziert werden."
			case .separatorOrder:
				"Die beiden Trenner stehen in der falschen Reihenfolge in der Menüleiste."
			case .itemGone:
				"Das Item existiert nicht mehr."
			case .eventSourceUnavailable:
				"CGEventSource konnte nicht erzeugt werden."
			case .eventCreationFailed:
				"Maus-Event konnte nicht erzeugt werden."
			case .eventDeliveryTimeout:
				"Maus-Event wurde nicht rechtzeitig zugestellt."
			case .verificationFailed(let name):
				"„\(name)“ landete nach mehreren Versuchen nicht an der erwarteten Position."
			}
		}
	}

	/// Ein eigenes Status-Item, das als Grenze zwischen zwei Sektionen dient.
	@MainActor
	private final class Separator {
		/// Breite im eingeklappten Zustand — so breit, dass alles links davon aus der
		/// Menüleiste geschoben wird.
		private static let collapsedLength: CGFloat = 10_000
		private static let expandedLength: CGFloat = 24

		private let item: NSStatusItem
		/// Menüleisten-Fenster, die es vor *dieser* Erzeugung schon gab — Grundlage der
		/// Diff-Erkennung in ``realizedWindowID()``.
		private let windowIDsBefore: Set<CGWindowID>
		private var cachedWindowID: CGWindowID?

		/// `true` = alles links von diesem Trenner ist aus dem sichtbaren Bereich geschoben.
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
				accessibilityDescription: "Bar Tool Trenner"
			)
			item.button?.image?.isTemplate = true
		}

		var windowID: CGWindowID? { cachedWindowID }
		var frame: CGRect? { cachedWindowID.flatMap(CGSBridge.frame(for:)) }

		/// CGWindowID, sobald der Trenner fertig gelayoutet in der Menüleiste steht.
		///
		/// `button.window.windowNumber` ist dafür seit macOS 26 unbrauchbar: Status-Items
		/// werden out-of-process gehostet, die lokale `NSWindow` meldet konstant
		/// `0x2_0000_0000` (live gemessen). Die echte ID ist stattdessen das
		/// Menüleisten-Fenster, das nach der Erzeugung neu in der CGS-Liste auftaucht.
		///
		/// Gewartet wird auf einen *stabilen* Rahmen statt auf einen festen Sleep: der Trenner
		/// fährt animiert ein (gemessen ~450 ms, von 12×10 auf 40×30 pt). Ein Drop auf einen
		/// Zwischenstand landet an der falschen Stelle.
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

	private static let log = Logger(subsystem: "de.andreduhme.BarTool", category: "DragHideEngine")

	private static let maxAttempts = 3
	/// Wie lange auf die Bestätigung am Session-Tap gewartet wird (Wert aus Ice).
	private static let scrombleTimeoutMilliseconds = 50
	/// Toleranz, weil macOS die Items nach einem Drop um Sub-Pixel neu ausrichtet.
	private static let tolerance: CGFloat = 1

	/// Grenze zwischen `visible` (rechts davon) und `hidden` (links davon).
	private var hiddenSeparator: Separator?
	/// Grenze zwischen `hidden` (rechts davon) und `alwaysHidden` (links davon). Liegt immer
	/// links vom ``hiddenSeparator`` — sichergestellt in ``prepareSeparators()``.
	private var alwaysHiddenSeparator: Separator?

	/// Wie weit die Leiste gerade aufgeklappt ist.
	enum Reveal {
		/// Nur `visible` — der Normalzustand.
		case none
		/// Zusätzlich `hidden`.
		case hidden
		/// Alles, auch `alwaysHidden`.
		case all
	}

	/// Nie sind beide Trenner gleichzeitig breit: es genügt, dass der jeweils rechte alles
	/// links von sich hinausschiebt. Zwei 10.000-pt-Items nebeneinander würden die Leiste
	/// ohne Not um 20.000 pt verschieben.
	var reveal: Reveal = .none {
		didSet {
			hiddenSeparator?.isCollapsed = hiddenSeparatorCollapses
			alwaysHiddenSeparator?.isCollapsed = alwaysHiddenSeparatorCollapses
		}
	}

	private var hiddenSeparatorCollapses: Bool { reveal == .none }
	private var alwaysHiddenSeparatorCollapses: Bool { reveal == .hidden }

	/// Fenster-IDs der eigenen Trenner, soweit angelegt — zum Ausschluss aus der verwalteten
	/// Item-Liste. Bewusst die WindowID, nicht PID/BundleID: genau in der Race, in der die
	/// Besitzer-Zuordnung eigene Fenster fälschlich dem Kontrollzentrum zuschreibt, bleibt
	/// die WindowID unberührt korrekt.
	var separatorWindowIDs: Set<CGWindowID> {
		Set([hiddenSeparator?.windowID, alwaysHiddenSeparator?.windowID].compactMap { $0 })
	}

	/// Wo das Item *tatsächlich* steht, gemessen an den Trennern.
	///
	/// `isOnScreen` taugt dafür nicht: `hidden` und `alwaysHidden` sind beide unsichtbar,
	/// solange nichts eingeblendet ist, und eingeblendet ist umgekehrt auch Verstecktes
	/// sichtbar. Die Lage relativ zu den Trennern stimmt dagegen in jedem Zustand.
	///
	/// - Returns: `nil`, wenn das Fenster verschwunden ist.
	func placement(of item: MenuBarItem) -> MenuBarLayout.Section? {
		guard let frame = CGSBridge.frame(for: item.windowID) else { return nil }
		// Ohne Trenner gibt es nichts, wovon etwas links liegen könnte.
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

	// MARK: Trenner

	/// Legt beide Trenner an (falls nötig) und wartet, bis sie stabil in der Leiste stehen.
	///
	/// Die Reihenfolge ist entscheidend: der `alwaysHidden`-Trenner muss links vom
	/// `hidden`-Trenner liegen, sonst kehrt sich jede Zuordnung um. macOS platziert ein neues
	/// Status-Item links von den bestehenden — deshalb strikt nacheinander, und jeder erst
	/// fertig realisiert, bevor der nächste dazukommt: sonst greift dessen WindowID-Diff noch
	/// das gerade erst erscheinende Fenster des Vorgängers ab. Zugesichert ist die Platzierung
	/// nirgends, also wird sie am Ende geprüft.
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

	/// Wohin gedroppt wird, damit das Item in der gewünschten Sektion landet — samt dem
	/// Trenner-Fenster, das der Drop adressiert.
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

		// Trenner anlegen und layoutfertig abwarten, *bevor* ihre Geometrie gelesen wird.
		try await prepareSeparators()

		// Cursor sichern und in jedem Fall wieder freigeben — auch wenn der Drag wirft.
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
				// Ein fehlgeschlagener Versuch beendet nicht die Serie — der nächste kann
				// durchkommen. Nur wenn alle scheitern, wirft ``verificationFailed``.
				Self.log.warning(
					"Attempt \(attempt) for \(item.displayName, privacy: .public) threw: \(error.localizedDescription, privacy: .public)"
				)
			}

			if await waitUntilPositioned(item, in: section) {
				Self.log.info("Moved \(item.displayName, privacy: .public) (attempt \(attempt))")
				return
			}
			Self.log.warning("Attempt \(attempt) for \(item.displayName, privacy: .public) failed")
			// ponytail: fester Delay statt Ice' "wakeUpItem"-Aufweckklick. Wenn sich im
			// Praxistest zeigt, dass eingeschlafene Prozesse den ersten Drag regelmäßig
			// verschlucken, hier einen Cmd-Down/Up an Ort und Stelle einschieben.
			try? await Task.sleep(for: .milliseconds(80))
		}

		// Sicherheitsnetz: falls ein mouseDown ohne wirksamen mouseUp durchkam, hier
		// definitiv loslassen, damit der Zielprozess nicht im Drag-Zustand bleibt.
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

		// Startpunkt bewusst weit außerhalb jedes Bildschirms: welches Item gezogen wird,
		// entscheiden die windowID-Felder des Events, nicht die Cursorposition. So gerät
		// kein anderes Item unter den simulierten Zeiger. (Technik aus Ice, MIT.)
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
		// Zwischen down und up wird bewusst nicht abgebrochen: ein mouseDown ohne mouseUp
		// hinterlässt im Zielprozess einen hängenden Drag.
		// `false` heißt: der Zielprozess hat den Drag nicht angenommen — der aussagekräftigste
		// Einzelwert bei der Fehlersuche, deshalb bleibt er als Debug-Log stehen.
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

	/// Stellt ein Maus-Event so zu, dass der Zielprozess es als echten Drag akzeptiert.
	///
	/// Ein reines `postToPid` genügt nicht — live verifiziert: der Drag lief fehlerfrei
	/// durch, das Item blieb aber exakt stehen. Das Event landet dabei nur in der
	/// Event-Queue der Ziel-App; das Fenstersystem sieht nie einen Drag beginnen, also
	/// startet die Umsortier-Mechanik der Menüleiste gar nicht erst.
	///
	/// Der Umweg: ein Null-Event an den Zielprozess posten und im zugehörigen Tap das
	/// echte Event an den *Session*-Tap weiterreichen. Erst wenn es dort beobachtet
	/// wurde — das System es also gesehen hat — geht es per `postToPid` an den Prozess.
	/// Technik ("scromble") 1:1 aus Ice (MIT), `MenuBarItemManager.scrombleEvent`.
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
						return nil // Das Null-Event selbst darf den Prozess nicht erreichen.
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

	/// Nach dem Drop ordnet macOS die Leiste animiert neu — Item *und* Trenner wandern
	/// dabei noch. Ein einzelner Vergleich direkt nach dem mouseUp trifft deshalb
	/// zuverlässig einen Zwischenstand (live gemessen: Rahmen überlappten sich um 18 pt,
	/// die Trennerbreite schwankte zwischen 38 und 41 pt). Also bis zum Einrasten prüfen.
	/// Verlangt zwei aufeinanderfolgende Treffer statt eines einzelnen: live beobachtet hat
	/// ein einzelner Treffer mitten in Apples eigener Neuanordnungs-Animation eine
	/// Zwischenposition als final durchgewunken — die Leiste sortierte sich danach nochmal
	/// um, das Item landete am Ende woanders, ohne dass hier ein Fehler geworfen wurde.
	private func waitUntilPositioned(
		_ item: MenuBarItem, in section: MenuBarLayout.Section
	) async -> Bool {
		var consecutiveHits = 0
		for attempt in 0..<40 {
			if attempt > 0 { try? await Task.sleep(for: .milliseconds(25)) }
			// Dieselbe Messung, mit der auch der Controller den Ist-Zustand liest — was hier
			// als erledigt durchgeht, kann dort nicht sofort wieder als falsch gelten.
			if placement(of: item) == section {
				consecutiveHits += 1
				if consecutiveHits >= 2 { return true }
			} else {
				consecutiveHits = 0
			}
		}
		return false
	}

	/// Posten eines mouseUp auf dem Item selbst, um einen eventuell hängenden Drag-Zustand
	/// im Zielprozess aufzulösen.
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

	/// Ohne das hier verwirft das Fenstersystem die synthetischen Events als
	/// "unterdrückt", solange kurz zuvor echte Eingaben stattfanden.
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

// MARK: - Selbsttest

extension DragHideEngine {
	/// Legt die Trenner an (falls noch nicht geschehen) und prüft die eine Annahme, die sich
	/// nicht aus dem Code ableiten lässt: dass macOS ein neues Status-Item *links* von den
	/// bestehenden platziert. Stimmt das nicht, kehrt sich die Bedeutung beider Sektionen um.
	///
	/// Aufrufbar über den Debug-Menüpunkt; live ist das sonst nicht nachvollziehbar, weil
	/// beide Trenner im Normalzustand außerhalb des Bildschirms liegen.
	@discardableResult
	func runSeparatorSelfTest() async -> Bool {
		do {
			// Wirft bereits bei vertauschter Reihenfolge (``DragError/separatorOrder``).
			try await prepareSeparators()
		} catch {
			print("[BarTool] Trenner-Selbsttest FEHLER: \(error.localizedDescription)")
			return false
		}
		guard
			let hidden = hiddenSeparator?.frame,
			let alwaysHidden = alwaysHiddenSeparator?.frame
		else {
			print("[BarTool] Trenner-Selbsttest FEHLER: kein Rahmen ermittelbar")
			return false
		}
		print(
			String(
				format: "[BarTool]   hidden-Trenner        x=%9.1f…%9.1f",
				hidden.minX, hidden.maxX
			)
		)
		print(
			String(
				format: "[BarTool]   alwaysHidden-Trenner  x=%9.1f…%9.1f",
				alwaysHidden.minX, alwaysHidden.maxX
			)
		)
		print("[BarTool] Trenner-Selbsttest: Reihenfolge stimmt (alwaysHidden liegt links)")
		return true
	}
}

// MARK: - CGEvent-Konstruktion

private extension CGEventField {
	/// Undokumentiertes Feld für die Fenster-ID eines Events. Rohwert übernommen aus Ice
	/// (MIT), Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift @ 11edd39115f3.
	static let windowID = CGEventField(rawValue: 0x33)!
}

private extension CGEvent {
	/// Erzeugt ein Maus-Event, das ein bestimmtes Menüleisten-Item adressiert.
	///
	/// Entscheidend sind die drei windowID-Felder: sie sagen dem Zielprozess, welches
	/// seiner Status-Item-Fenster gemeint ist — unabhängig davon, wo der Zeiger steht.
	/// Feldauswahl übernommen aus Ice (MIT), `CGEvent.menuBarItemEvent`.
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
