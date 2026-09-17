import Foundation

/// Persistierbare Zuordnung von Menüleisten-Items zu den drei Sektionen.
///
/// Gespeichert werden ``MenuBarItemID/storageKey``-Strings, keine Fenster-IDs — die sind
/// nur sitzungsgültig. Die Reihenfolge innerhalb einer Sektion ist die spätere
/// Anzeigereihenfolge.
struct MenuBarLayout: Codable, Equatable, Sendable {
	enum Section: String, Codable, CaseIterable, Sendable {
		case visible
		case hidden
		case alwaysHidden
	}

	private(set) var visible: [String] = []
	private(set) var hidden: [String] = []
	private(set) var alwaysHidden: [String] = []

	init(visible: [String] = [], hidden: [String] = [], alwaysHidden: [String] = []) {
		self.visible = visible
		self.hidden = hidden
		self.alwaysHidden = alwaysHidden
	}

	func keys(in section: Section) -> [String] {
		switch section {
		case .visible: visible
		case .hidden: hidden
		case .alwaysHidden: alwaysHidden
		}
	}

	func section(of key: String) -> Section? {
		Section.allCases.first { keys(in: $0).contains(key) }
	}

	/// Verschiebt einen Schlüssel in eine Sektion. Bereits vorhandene Vorkommen in *allen*
	/// Sektionen werden vorher entfernt, ein Schlüssel ist also nie doppelt einsortiert.
	///
	/// - Parameter index: Zielposition innerhalb der Sektion; `nil` oder außerhalb des
	///   Bereichs hängt ans Ende an.
	mutating func move(_ key: String, to section: Section, at index: Int? = nil) {
		visible.removeAll { $0 == key }
		hidden.removeAll { $0 == key }
		alwaysHidden.removeAll { $0 == key }

		let insert = { (list: inout [String]) in
			let position = min(max(index ?? list.count, 0), list.count)
			list.insert(key, at: position)
		}
		switch section {
		case .visible: insert(&visible)
		case .hidden: insert(&hidden)
		case .alwaysHidden: insert(&alwaysHidden)
		}
	}

	/// Sortiert bisher unbekannte Schlüssel nach `visible` ein.
	///
	/// Schlüssel, die gerade *nicht* in `knownKeys` stehen, bleiben bewusst erhalten: eine
	/// App kann beendet sein und später zurückkommen, ihre Sektionszuordnung soll das
	/// überleben.
	mutating func reconcile(with knownKeys: [String]) {
		for key in knownKeys where section(of: key) == nil {
			visible.append(key)
		}
	}
}

// MARK: - Selbsttest

extension MenuBarLayout {
	/// Minimaler Selbsttest ohne Test-Framework; aufrufbar über den Debug-Menüpunkt.
	/// Gibt `true` zurück, wenn alle Prüfungen bestanden wurden.
	@discardableResult
	static func runSelfTest() -> Bool {
		var failures: [String] = []
		func check(_ condition: Bool, _ message: String) {
			if !condition { failures.append(message) }
		}

		var layout = MenuBarLayout()
		check(layout.section(of: "a") == nil, "Leeres Layout darf keinen Treffer liefern")

		layout.reconcile(with: ["a", "b", "c"])
		check(layout.visible == ["a", "b", "c"], "reconcile sortiert Unbekanntes nach visible")
		check(layout.section(of: "b") == .visible, "section(of:) findet b in visible")

		layout.reconcile(with: ["a", "b", "c"])
		check(layout.visible == ["a", "b", "c"], "reconcile ist idempotent")

		layout.move("b", to: .hidden)
		check(layout.visible == ["a", "c"], "move entfernt aus der Quellsektion")
		check(layout.hidden == ["b"], "move fügt in die Zielsektion ein")

		layout.move("a", to: .hidden, at: 0)
		check(layout.hidden == ["a", "b"], "move respektiert den Index")

		layout.move("c", to: .alwaysHidden, at: 99)
		check(layout.alwaysHidden == ["c"], "Index außerhalb des Bereichs hängt ans Ende an")

		layout.move("a", to: .alwaysHidden)
		check(layout.hidden == ["b"], "Umsortieren hinterlässt kein Duplikat")
		check(layout.alwaysHidden == ["c", "a"], "Umsortieren hängt korrekt an")

		// Entfernte App behält ihre Zuordnung.
		layout.reconcile(with: ["b"])
		check(layout.alwaysHidden == ["c", "a"], "reconcile entfernt keine verschwundenen Schlüssel")

		do {
			let data = try JSONEncoder().encode(layout)
			let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: data)
			check(decoded == layout, "Codable-Roundtrip erhält das Layout")
		} catch {
			failures.append("Codable-Roundtrip warf \(error)")
		}

		if failures.isEmpty {
			print("[BarT] MenuBarLayout-Selbsttest: alle Prüfungen bestanden")
		} else {
			for failure in failures {
				print("[BarT] MenuBarLayout-Selbsttest FEHLER: \(failure)")
			}
		}
		assert(failures.isEmpty, "MenuBarLayout-Selbsttest fehlgeschlagen")
		return failures.isEmpty
	}
}
