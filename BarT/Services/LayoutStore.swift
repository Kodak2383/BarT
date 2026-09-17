import Foundation

/// Persistiert ``MenuBarLayout`` als JSON in `UserDefaults`.
@MainActor
final class LayoutStore {
	private static let defaultsKey = "de.andreduhme.BarT.layout"

	private let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	func load() -> MenuBarLayout {
		guard let data = defaults.data(forKey: Self.defaultsKey) else { return MenuBarLayout() }
		return (try? JSONDecoder().decode(MenuBarLayout.self, from: data)) ?? MenuBarLayout()
	}

	func save(_ layout: MenuBarLayout) {
		guard let data = try? JSONEncoder().encode(layout) else { return }
		defaults.set(data, forKey: Self.defaultsKey)
	}
}
