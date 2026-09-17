import Foundation

/// Persistable assignment of menu bar items to the three sections.
///
/// What gets stored are ``MenuBarItemID/storageKey`` strings, not window IDs — those are valid
/// for one session only. The order within a section is the later display order.
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

	/// Moves a key into a section. Existing occurrences in *all* sections are removed first,
	/// so a key is never filed twice.
	///
	/// - Parameter index: target position within the section; `nil` or out of range appends.
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

	/// Files so far unknown keys under `visible`, and drops stale ones from it.
	///
	/// Keys missing from `knownKeys` are deliberately kept in `hidden` and `alwaysHidden`: an
	/// app may have quit and come back later, and a deliberate assignment should survive that.
	///
	/// In `visible` they are dropped instead, because there they carry no information — a key
	/// filed nowhere counts as visible anyway, so the entry says exactly what its absence
	/// would. Without this the layout grows with every app ever seen and never shrinks (76
	/// entries for 22 real items, measured).
	mutating func reconcile(with knownKeys: [String]) {
		let known = Set(knownKeys)
		visible.removeAll { !known.contains($0) }
		for key in knownKeys where section(of: key) == nil {
			visible.append(key)
		}
	}
}

// MARK: - Self-test

extension MenuBarLayout {
	/// Minimal self-test without a test framework; callable from the debug menu item.
	/// Returns `true` when every check passed.
	@discardableResult
	static func runSelfTest() -> Bool {
		var failures: [String] = []
		func check(_ condition: Bool, _ message: String) {
			if !condition { failures.append(message) }
		}

		var layout = MenuBarLayout()
		check(layout.section(of: "a") == nil, "an empty layout must not report a match")

		layout.reconcile(with: ["a", "b", "c"])
		check(layout.visible == ["a", "b", "c"], "reconcile files unknown keys under visible")
		check(layout.section(of: "b") == .visible, "section(of:) finds b in visible")

		layout.reconcile(with: ["a", "b", "c"])
		check(layout.visible == ["a", "b", "c"], "reconcile is idempotent")

		layout.move("b", to: .hidden)
		check(layout.visible == ["a", "c"], "move removes from the source section")
		check(layout.hidden == ["b"], "move inserts into the target section")

		layout.move("a", to: .hidden, at: 0)
		check(layout.hidden == ["a", "b"], "move respects the index")

		layout.move("c", to: .alwaysHidden, at: 99)
		check(layout.alwaysHidden == ["c"], "an out-of-range index appends")

		layout.move("a", to: .alwaysHidden)
		check(layout.hidden == ["b"], "re-filing leaves no duplicate behind")
		check(layout.alwaysHidden == ["c", "a"], "re-filing appends correctly")

		// An app that went away keeps a deliberate assignment.
		layout.reconcile(with: ["b"])
		check(layout.alwaysHidden == ["c", "a"], "reconcile keeps vanished keys that were filed")

		// ...but a vanished key in `visible` is dropped, since its absence means the same thing.
		var pruning = MenuBarLayout(visible: ["gone", "here"], hidden: ["filed"])
		pruning.reconcile(with: ["here"])
		check(pruning.visible == ["here"], "reconcile drops vanished keys from visible")
		check(pruning.hidden == ["filed"], "reconcile leaves hidden alone")
		pruning.reconcile(with: ["here", "new"])
		check(pruning.visible == ["here", "new"], "a returning key is filed under visible again")

		do {
			let data = try JSONEncoder().encode(layout)
			let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: data)
			check(decoded == layout, "the Codable round trip preserves the layout")
		} catch {
			failures.append("the Codable round trip threw \(error)")
		}

		if failures.isEmpty {
			print("[BarT] MenuBarLayout self-test: all checks passed")
		} else {
			for failure in failures {
				print("[BarT] MenuBarLayout self-test FAILED: \(failure)")
			}
		}
		assert(failures.isEmpty, "MenuBarLayout self-test failed")
		return failures.isEmpty
	}
}
