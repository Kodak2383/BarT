import AppKit
import ApplicationServices
import CoreGraphics

/// Enumeriert alle Menüleisten-Items aller laufenden Apps.
///
/// Rein lesend — diese Klasse verändert nichts an der Menüleiste.
@MainActor
final class MenuBarItemSource: NSObject {
	private(set) var items: [MenuBarItem] = []

	/// Liefert die Fenster-IDs, die nie als Item auftauchen sollen — Bar Tools eigene
	/// Status-Items (Icon, Trenner). Über die WindowID statt PID/BundleID, weil letztere
	/// direkt nach einem Drag kurzzeitig falsch zugeordnet werden (siehe ``MenuBarController``).
	///
	/// Bewusst ein Closure statt eines Sets: die Trenner entstehen erst unterwegs, und
	/// zwischen ihrer Erzeugung und dem Nachtragen in ein Set läge ein Poll-Fenster von bis zu
	/// zwei Sekunden, in dem sie als ganz normale, verwaltbare Items durchrutschen — mit dem
	/// Ergebnis, dass die App anfängt, ihre eigenen Trenner zu verschieben.
	var excludedWindowIDs: () -> Set<CGWindowID> = { [] }

	/// Wird nur aufgerufen, wenn sich die Item-Liste tatsächlich geändert hat.
	var onChange: (([MenuBarItem]) -> Void)?

	private var pollTask: Task<Void, Never>?

	/// CGS meldet keine Änderungen; es gibt keine Notification für "Item hinzugefügt".
	/// Deshalb Polling als Basis, die Workspace-Notifications sind nur eine
	/// Latenz-Verbesserung für den häufigsten Fall (App startet/beendet sich).
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

	/// Liest die Menüleiste sofort aus, ohne den Timer zu benötigen.
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
		// Eine frisch gestartete App registriert ihr Status-Item erst einige
		// hundert Millisekunden nach der Launch-Notification.
		Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(750))
			self?.refresh()
		}
	}

	// MARK: Enumeration

	/// Fensterebene echter Status-Items. Die Menüleiste selbst (Owner "Window Server")
	/// taucht in derselben CGS-Liste auf, liegt aber auf Ebene 24 und ist kein Item.
	private static let statusItemLayer = Int(CGWindowLevelForKey(.statusWindow))

	/// Maximale Abweichung zwischen AX- und CGS-Mitte eines Items. Live gemessen: 0.0 pt.
	/// Items liegen mindestens 24 pt auseinander, eine Fehlzuordnung ist damit ausgeschlossen.
	private static let midXTolerance: CGFloat = 2

	/// Liefert alle Menüleisten-Items, sortiert von links nach rechts.
	/// - Parameter excludedWindowIDs: Fenster, die nie als Item zurückkommen sollen
	///   (Bar Tools eigene Status-Items).
	static func enumerate(excluding excludedWindowIDs: Set<CGWindowID> = []) -> [MenuBarItem] {
		let windowIDs = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: false))
		guard !windowIDs.isEmpty else { return [] }
		let onScreen = Set(CGSBridge.menuBarWindowIDs(onScreenOnly: true))

		// `CGWindowListCreateDescriptionFromArray` liefert für Menüleisten-Fenster
		// verifiziert eine leere Liste. Deshalb die vollständige Fensterliste holen und
		// gegen die CGS-IDs schneiden — ein Aufruf, ~100 Einträge.
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

		// Zweistufig: zuerst die Rohdaten sammeln und nach x sortieren, danach erst pro
		// Gruppe (gleicher bundleID+title) die Geschwister-Position vergeben — die braucht
		// die endgültige Links-nach-rechts-Reihenfolge, um stabil zu sein.
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
				// Eigene Items (Status-Icon, Trenner) gehören nie in die verwaltete Liste:
				// sie sind kein normales, vom Nutzer versteck-/zeigbares Item. Live
				// beobachtet, hat ihre Aufnahme eine Endlosschleife ausgelöst — die
				// Reconcile-Logik hielt den (fast immer "nicht sichtbaren") Trenner für ein
				// kaputtes Item und versuchte ihn endlos zu reparieren.
				// Über die WindowID statt PID/BundleID: beide waren direkt nach einem Drag
				// live falsch (fälschlich dem Kontrollzentrum zugeordnet) — die WindowID ist
				// von dieser Race unberührt.
				!excludedWindowIDs.contains(windowID),
				let hostPID = description[kCGWindowOwnerPID as String] as? pid_t,
				// Frame live über CGS statt aus kCGWindowBounds: die Beschreibung ist ein
				// Snapshot und liegt nach einem Drag messbar hinter der Realität zurück.
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

	// MARK: Besitzer-Ermittlung über die Bedienungshilfen

	/// Ein von einer App gemeldetes eigenes Menüleisten-Item.
	private struct ItemOwner {
		/// Horizontale Mitte in globalen CG-Koordinaten.
		let midX: CGFloat
		let pid: pid_t
		let bundleID: String
	}

	/// Liest aus jeder laufenden App ihre *eigenen* Menüleisten-Items aus.
	///
	/// `kCGWindowOwnerPID` ist für Status-Item-Fenster unbrauchbar: macOS rendert sie in
	/// einem Hosting-Prozess, die Fensterliste meldet deshalb für *alle* Items dieselbe PID.
	/// Live verifiziert auf macOS 26.6.2 — alle 21 Items kamen als `com.apple.controlcenter`
	/// (pid 674) zurück, obwohl 11 verschiedene Apps beteiligt waren. Auch der CGS-Weg
	/// (`CGSGetWindowOwner`) liefert dieselbe Hosting-Connection und hilft nicht.
	///
	/// Die einzige belastbare Quelle ist die AX-Hierarchie: `kAXExtrasMenuBarAttribute`
	/// liefert pro App nur deren eigene Items. Zugeordnet wird über die horizontale Mitte —
	/// die AX-Rahmen sind gegenüber den CGS-Rahmen um 1 pt aufgeweitet, die Mitte stimmt
	/// exakt. (Ansatz wie in "Ice", MIT, github.com/jordanbaird/Ice.)
	private static func accessibilityOwners() -> [ItemOwner] {
		guard AccessibilityPermission.isTrusted else { return [] }

		var owners: [ItemOwner] = []
		for app in NSWorkspace.shared.runningApplications {
			let element = AXUIElementCreateApplication(app.processIdentifier)
			// Ohne Timeout hält ein hängender Prozess den ganzen Poll-Durchlauf auf.
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
				// Das Kontrollzentrum meldet auch nicht platzierte Items; die haben einen
				// Nullrahmen und würden sonst auf die Mitte 0 matchen.
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

	/// Konsolen-Dump für den Debug-Menüpunkt.
	static func debugDump() {
		let items = enumerate()
		let owners = Set(items.map(\.id.bundleID))
		print("[BarTool] \(items.count) Menüleisten-Items aus \(owners.count) Apps (links → rechts):")
		if !AccessibilityPermission.isTrusted {
			print("[BarTool]   Hinweis: keine Bedienungshilfen-Berechtigung — ohne sie fällt die")
			print("[BarTool]   Besitzer-Ermittlung auf den Hosting-Prozess zurück und ist falsch.")
		}
		if items.contains(where: { $0.id.title.isEmpty }) {
			print("[BarTool]   Hinweis: Items ohne Titel lassen sich nicht einzeln persistieren.")
		}
		for item in items {
			let flag = item.isOnScreen ? "sichtbar " : "versteckt"
			let frame = String(
				format: "x=%7.1f w=%5.1f", item.frame.minX, item.frame.width
			)
			print("[BarTool]   \(flag)  \(frame)  win=\(item.windowID) pid=\(item.ownerPID)  \(item.storageKey)")
		}
	}
}
