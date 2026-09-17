import AppKit
import CoreGraphics
import Observation

/// Verbindet Item-Enumeration, Layout-Persistenz und Drag-Engine zu einem Ganzen.
///
/// Einzige Quelle der Wahrheit für die Settings-UI: sie liest ``items`` und ``layout``
/// und ruft ``moveItem(_:to:)`` auf, den Rest (Speichern, tatsächliches Verschieben in der
/// Menüleiste) übernimmt der Controller.
@MainActor
@Observable
final class MenuBarController {
	private(set) var items: [MenuBarItem] = []
	private(set) var layout: MenuBarLayout
	private(set) var lastError: String?

	/// `true` = die `hidden`-Sektion ist gerade vorübergehend eingeblendet. `alwaysHidden`
	/// bleibt dabei weg — dafür ist der zweite Trenner da.
	private(set) var isRevealed = false

	/// Wird bei jedem Wechsel des Einblend-Zustands gerufen, auch beim automatischen Zuklappen
	/// — das liefe sonst am Symbol des Menüleisten-Icons vorbei.
	///
	/// Bewusst nicht an ``isRevealed`` gekoppelt: das Feld hinkt beim Zuklappen absichtlich um
	/// die Animationsdauer hinterher, ein Symbolwechsel soll das nicht.
	var onRevealChanged: ((Bool) -> Void)?

	private let source = MenuBarItemSource()
	private let engine = DragHideEngine()
	private let store: LayoutStore

	private var hotKey: GlobalHotKey?

	/// `false`, wenn ``GlobalHotKey/displayName`` schon von einer anderen App belegt ist.
	private(set) var isHotKeyRegistered = false

	/// Alle Drags laufen streng nacheinander über diese Kette — nie parallel. Live
	/// beobachtet: zwei gleichzeitige Drags auf dasselbe Item (Picker-Klick + Reconcile-Loop
	/// trafen sich) haben sich gegenseitig kaputtgemacht (Event-Taps auf derselben pid).
	private var operationChain: Task<Void, Never> = Task {}

	/// Bremse gegen endloses Hin- und Herziehen zweier Nachbarn (siehe ``OscillationGuard``).
	private var oscillation = OscillationGuard()

	/// BarTs eigene Menüleisten-Fenster (Icon, beide Trenner) — dürfen nie als verwaltbares
	/// Item auftauchen. Die Trenner kommen aus der Engine, das Status-Icon meldet sich per
	/// ``excludeOwnWindow(_:)`` von außen (siehe AppDelegate).
	private var excludedWindowIDs: Set<CGWindowID> = []

	/// Registriert ein zusätzliches eigenes Fenster (z.B. das primäre Status-Icon aus
	/// AppDelegate) als von der verwalteten Liste auszuschließen.
	func excludeOwnWindow(_ windowID: CGWindowID) {
		excludedWindowIDs.insert(windowID)
	}

	init(store: LayoutStore = LayoutStore()) {
		self.store = store
		self.layout = store.load()
	}

	func start() {
		// Grundzustand ist eingeklappt: nur so schiebt der breite Trenner alles links von
		// sich aus der Menüleiste. Aufgeklappt wird ausschließlich vorübergehend über
		// ``toggleReveal()``.
		engine.reveal = .none
		// Die Trenner-IDs bei jeder Enumeration frisch abfragen, statt sie nachzutragen:
		// sonst rutschen sie zwischen Erzeugung und Nachtrag als Items durch.
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
		// Ohne das hier lief nie der 2s-Poll: die Liste hat sich dann nie von selbst
		// aktualisiert (z.B. falsch zugeordnete Namen direkt nach dem Start, bevor die
		// Bedienungshilfen-Berechtigung durchgereicht war), sondern nur, wenn irgendeine
		// Aktion (Picker-Klick, Drag-Abschluss) zufällig eine frische Momentaufnahme zog.
		source.start()
	}

	/// Blendet die `hidden`-Sektion vorübergehend ein bzw. wieder aus — die Geste, mit der man
	/// überhaupt an ein verstecktes Item herankommt (Klick auf BarTs Status-Item).
	/// `alwaysHidden` bleibt bewusst weg; genau dafür gibt es die Sektion.
	///
	/// ponytail: kein Zuklappen nach Zeit — nur der Klick daneben (siehe
	/// ``startOutsideClickMonitor()``).
	///
	/// - Parameter includingAlwaysHidden: blendet zusätzlich `alwaysHidden` ein (⌥-Klick).
	///   Aus einem der beiden Zustände heraus auf den anderen umzuschalten klappt nicht zu,
	///   sondern wechselt nur die Tiefe — erst dieselbe Geste noch einmal klappt zu.
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
		// Mehrfach zuklappen ist folgenlos, würde aber jedes Mal einen weiteren
		// Nachlauf-``Task`` starten.
		guard engine.reveal != .none else { return }
		engine.reveal = .none
		stopOutsideClickMonitor()
		onRevealChanged?(false)
		// ``isRevealed`` bleibt bis zum Ende der Animation gesetzt: die Trenner ändern ihre
		// Breite animiert (~450 ms, siehe DragHideEngine), jede Positionsmessung ist so lange
		// ein Zwischenstand. Ein Abgleich darauf würde richtig einsortierte Items erneut ziehen.
		Task {
			try? await Task.sleep(for: .milliseconds(500))
			// Inzwischen wieder eingeblendet? Dann gehört das Feld dem neuen Zustand.
			guard self.engine.reveal == .none else { return }
			self.isRevealed = false
			// Nachholen, was im eingeblendeten Zustand ausgesetzt war (neu erschienene Items,
			// Sektionswechsel aus den Einstellungen).
			self.handleItemsChanged(self.source.snapshot())
		}
	}

	// MARK: Klick daneben

	private var outsideClickMonitor: Any?

	/// Klappt wieder zu, sobald der Nutzer irgendwo außerhalb der Menüleiste klickt.
	///
	/// Klicks *in* der Menüleiste sind ausgenommen: dafür wurde ja eingeblendet, und ein
	/// sofortiges Zuklappen würde das gerade angeklickte Item unter dem Cursor wegziehen.
	/// Die eigene App liefert an einen globalen Monitor ohnehin nichts — ein Klick auf Bar
	/// Tools eigenes Icon läuft deshalb ausschließlich über ``toggleReveal()``.
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

	/// `visibleFrame` endet oben genau unterhalb der Menüleiste — was darüber liegt, ist sie.
	private static func isInMenuBar(_ location: NSPoint) -> Bool {
		guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
			return false
		}
		return location.y > screen.visibleFrame.maxY
	}

	/// Debug: prüft, was sich nur am laufenden System prüfen lässt — die Reihenfolge der
	/// Trenner und ob der Hotkey überhaupt registriert werden konnte.
	func runStartupSelfTest() async {
		await engine.runSeparatorSelfTest()
		print(
			"[BarT] Hotkey \(GlobalHotKey.displayName): "
				+ (isHotKeyRegistered ? "registriert" : "FEHLER — bereits belegt")
		)
	}

	/// Verschiebt ein Item in eine andere Sektion, speichert das Layout und wendet es an.
	///
	/// Arbeitet bewusst mit einer frischen Momentaufnahme statt der zwischengespeicherten
	/// ``items``-Liste: die wird nur beim Poll aktualisiert (bis zu 2 s Verzögerung), enthielte
	/// also direkt nach einem eigenen Drag womöglich ein Item, das es gar nicht mehr gibt.
	func moveItem(_ key: String, to section: MenuBarLayout.Section) {
		layout.move(key, to: section)
		store.save(layout)
		// Ausdrückliche Nutzerentscheidung — auch ein zuvor festgefahrener Schlüssel bekommt
		// damit wieder ein volles Drag-Budget (siehe ``OscillationGuard``).
		oscillation.release(key)
		if lastError != nil { lastError = nil }
		handleItemsChanged(source.snapshot())
	}

	private func handleItemsChanged(_ items: [MenuBarItem]) {
		self.items = items
		layout.reconcile(with: items.map(\.storageKey))
		store.save(layout)
		// Eingeblendet wird nicht abgeglichen: die Trenner sind dann in Bewegung (bzw. gerade
		// erst zur Ruhe gekommen), und wer die eingeblendete Leiste benutzt, will darin keine
		// automatischen Drags. ``toggleReveal()`` holt den Abgleich beim Zuklappen nach.
		guard !isRevealed else { return }
		var pending = 0
		for item in items {
			guard let section = layout.section(of: item.storageKey) else { continue }
			if apply(item, to: section) { pending += 1 }
		}
		// Nur wenn *jedes* Item dort steht, wo seine Sektion es hinhaben will, ist die Lage
		// wirklich sauber — erst dann ist ein Zurücksetzen der Bremse gefahrlos, weil daraus
		// per Definition kein weiterer Drag folgt.
		if pending == 0 { oscillation.reset() }
	}

	/// Bringt ein einzelnes Item in die Sektion, die das Layout vorgibt.
	/// Kein Aufwand, wenn es dort schon steht — jeder Drag ist sichtbar (Cursor, Animation).
	///
	/// - Returns: `true`, wenn das Item *nicht* dort steht, wo seine Sektion es hinhaben will —
	///   unabhängig davon, ob deswegen wirklich gezogen wird. Der Aufrufer erkennt daran, ob
	///   ein Abgleich vollständig zur Ruhe gekommen ist.
	@discardableResult
	private func apply(_ item: MenuBarItem, to section: MenuBarLayout.Section) -> Bool {
		guard engine.placement(of: item) != section else { return false }
		let key = item.storageKey
		// Festgefahrene Schlüssel gar nicht erst einreihen: die Operation würde nur warten,
		// den Trenner animieren und am Ende doch nichts tun.
		guard !oscillation.isStuck(key) else { return true }
		let previous = operationChain
		operationChain = Task {
			await previous.value

			// Hat der Nutzer inzwischen eingeblendet, sind die Trenner in Bewegung und jede
			// Messung ein Zwischenstand (siehe ``handleItemsChanged(_:)``) — aufgestaute
			// Korrekturen fallen lassen, ``toggleReveal()`` holt sie beim Zuklappen nach.
			guard !self.isRevealed else { return }
			// Neu prüfen statt der beim Aufruf eingefangenen Momentaufnahme zu vertrauen:
			// bis diese Operation an der Reihe ist, kann ein vorheriger Drag den Zustand
			// schon korrigiert haben (z.B. Kollateral-Verschiebung durch Reconcile geheilt).
			guard
				let current = self.items.first(where: { $0.storageKey == key }),
				self.engine.placement(of: current) != section
			else { return }
			// Letzte Gelegenheit abzubrechen, bevor echte Mausevents über die Menüleiste des
			// Nutzers laufen: hat dieser Schlüssel sein Budget aufgebraucht, bleibt das Item
			// stehen, wo es gerade ist. Bewusst ohne abschließendes Neu-Enumerieren — das
			// würde dieselbe Korrektur sofort wieder anstoßen.
			guard self.oscillation.allowDrag(key) else {
				self.lastError = """
					„\(current.displayName)“ ließ sich nicht stabil positionieren — vermutlich \
					zieht ein direkt daneben liegendes Item es bei jedem Verschieben wieder mit. \
					Es bleibt jetzt dort stehen, wo es zuletzt gelandet ist; eine erneute \
					Auswahl in der Liste startet einen neuen Versuch.
					"""
				return
			}

			// Zurück nach `visible` wird am *rechten* Rand des hidden-Trenners gedroppt — und
			// der liegt eingeklappt am äußersten Ende der Leiste, also an der falschen Stelle.
			// Für die anderen beiden Sektionen zählt der linke Rand, der stimmt immer.
			let needsRoom = section == .visible && self.engine.reveal == .none
			if needsRoom {
				self.engine.reveal = .hidden
				// Trenner-Breite ändert sich animiert (~450 ms, siehe DragHideEngine).
				// Ohne Wartezeit liest performDrag() eine Zwischenposition und der Drop
				// landet daneben.
				try? await Task.sleep(for: .milliseconds(500))
			}
			// Nur zurücknehmen, wenn der Nutzer nicht inzwischen selbst eingeblendet hat: ein
			// Drag dauert Sekunden, und dann gehören die Trenner ihm, nicht dieser Operation.
			defer { if needsRoom, !self.isRevealed { self.engine.reveal = .none } }
			do {
				try await self.engine.move(current, to: section)
			} catch {
				self.lastError = error.localizedDescription
			}
			// Kurz warten, bevor neu eingelesen wird: die Bedienungshilfen-Baumstruktur
			// (für die Besitzer-Zuordnung) hinkt der Fenstergeometrie unmittelbar nach einem
			// Drag kurz hinterher — live beobachtet, hat ein *sofortiges* Re-Enumerate genau
			// die gerade bewegten Fenster (auch unsere eigenen!) fälschlich dem
			// Kontrollzentrum zugeordnet, weil die AX-Position noch die alte war.
			try? await Task.sleep(for: .milliseconds(300))
			// Neu einlesen und abgleichen, statt bis zu 2 s auf den nächsten Poll zu warten:
			// heilt ein versehentlich mitgezogenes Nachbar-Item (Kollateralschaden, dessen
			// Sektion weiterhin "sichtbar" ist) zeitnah statt erst beim Poll, und sorgt
			// dafür, dass ein direkt folgender Gegenzug frische Daten sieht.
			self.handleItemsChanged(self.source.snapshot())
		}
		return true
	}
}

// MARK: - Pendel-Bremse

/// Begrenzt, wie oft ein Item automatisch nachkorrigiert wird, bevor es in Ruhe gelassen wird.
///
/// Mit nur einem Trenner lassen sich zwei physisch benachbarte Items nicht unabhängig
/// positionieren: ein Drag garantiert nur die Lage des *gezogenen* Items relativ zum Trenner,
/// der Nachbar rutscht mit (bekannte Grenze der Technik, siehe ``DragHideEngine``). Die
/// Selbstheilung am Ende von ``MenuBarController/apply(_:to:)`` korrigiert daraufhin den
/// Nachbarn — was das erste Item wieder verstellt. Live beobachtet mit Stats' `Disk_mini` und
/// `RAM_mini`: endlos, mit echten Mausevents über der Menüleiste des Nutzers.
///
/// Deshalb: je Schlüssel werden die tatsächlich ausgeführten Drags gezählt, über dem Limit
/// gilt er als festgefahren und wird gar nicht mehr automatisch korrigiert. Zurückgesetzt wird
/// *nur* über ``reset()`` (alle Items stehen richtig — daraus folgt per Definition kein
/// weiterer Drag) oder ``release(_:)`` (ausdrücklicher Nutzerwunsch). Ausdrücklich **nicht**
/// zurückgesetzt wird, wenn ein einzelnes Item gerade richtig steht: genau das wechselt beim
/// Pendeln ja ständig, ein solcher Reset würde die Bremse aushebeln. Damit ist die Zahl der
/// Drags ohne Nutzerinteraktion nach oben beschränkt (Limit × Anzahl Items).
struct OscillationGuard {
	/// Drei Versuche reichen für jeden gutartigen Fall — ein Item braucht normalerweise einen.
	static let limit = 3

	private var dragCounts: [String: Int] = [:]
	private var stuckKeys: Set<String> = []

	func isStuck(_ key: String) -> Bool { stuckKeys.contains(key) }

	/// Meldet einen unmittelbar bevorstehenden Drag an.
	/// - Returns: `false`, wenn die Bremse greift — dann nicht ziehen.
	mutating func allowDrag(_ key: String) -> Bool {
		guard !stuckKeys.contains(key) else { return false }
		let count = (dragCounts[key] ?? 0) + 1
		dragCounts[key] = count
		guard count > Self.limit else { return true }
		stuckKeys.insert(key)
		return false
	}

	/// Ausdrücklicher Nutzerwunsch für diesen Schlüssel: volles Budget, auch wenn er
	/// festgefahren war.
	mutating func release(_ key: String) {
		stuckKeys.remove(key)
		dragCounts[key] = nil
	}

	/// Alles sitzt — nur in diesem Zustand aufrufen.
	mutating func reset() {
		guard !dragCounts.isEmpty || !stuckKeys.isEmpty else { return }
		dragCounts.removeAll()
		stuckKeys.removeAll()
	}
}

// MARK: Selbsttest

extension OscillationGuard {
	/// Minimaler Selbsttest ohne Test-Framework; aufrufbar über den Debug-Menüpunkt.
	/// Live lässt sich das Pendeln nicht reproduzierbar auslösen — hier schon.
	@discardableResult
	static func runSelfTest() -> Bool {
		var failures: [String] = []
		func check(_ condition: Bool, _ message: String) {
			if !condition { failures.append(message) }
		}

		var normal = OscillationGuard()
		check(normal.allowDrag("a"), "erster Drag ist erlaubt")
		normal.reset()
		for step in 1...limit {
			check(normal.allowDrag("a"), "nach reset() wieder volles Budget (Schritt \(step))")
		}
		check(!normal.allowDrag("a"), "Budget ist nach \(limit) Drags aufgebraucht")
		check(normal.isStuck("a"), "aufgebrauchtes Budget fährt den Schlüssel fest")

		// Der eigentliche Fall: zwei Nachbarn stören sich abwechselnd, ein Abgleich kommt nie
		// zur Ruhe — also wird auch nie zurückgesetzt.
		var pingPong = OscillationGuard()
		var drags = 0
		for _ in 0..<100 {
			for key in ["disk", "ram"] where pingPong.allowDrag(key) { drags += 1 }
		}
		check(drags == 2 * limit, "Pendeln endet nach \(2 * limit) Drags, waren \(drags)")
		check(
			pingPong.isStuck("disk") && pingPong.isStuck("ram"),
			"beide Nachbarn sind am Ende festgefahren"
		)

		pingPong.release("disk")
		check(!pingPong.isStuck("disk"), "release() löst den Schlüssel wieder")
		check(pingPong.allowDrag("disk"), "release() gibt einen neuen Versuch frei")
		check(pingPong.isStuck("ram"), "release() wirkt nur auf den genannten Schlüssel")

		if failures.isEmpty {
			print("[BarT] OscillationGuard-Selbsttest: alle Prüfungen bestanden")
		} else {
			for failure in failures {
				print("[BarT] OscillationGuard-Selbsttest FEHLER: \(failure)")
			}
		}
		assert(failures.isEmpty, "OscillationGuard-Selbsttest fehlgeschlagen")
		return failures.isEmpty
	}
}
