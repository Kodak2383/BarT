import SwiftUI

struct SettingsView: View {
	let controller: MenuBarController

	var body: some View {
		TabView {
			GeneralSettingsTab(controller: controller)
				.tabItem {
					Label("Allgemein", systemImage: "gear")
				}
			ItemsSettingsTab(controller: controller)
				.tabItem {
					Label("Items", systemImage: "menubar.rectangle")
				}
		}
		.padding()
		.frame(width: 480, height: 360)
	}
}

private struct GeneralSettingsTab: View {
	let controller: MenuBarController

	private let loginItems = LoginItemManager()

	@State private var launchAtLogin: Bool
	@State private var isAccessibilityTrusted = AccessibilityPermission.isTrusted

	init(controller: MenuBarController) {
		self.controller = controller
		_launchAtLogin = State(initialValue: LoginItemManager().isRegistered())
	}

	var body: some View {
		Form {
			Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
				.onChange(of: launchAtLogin) { _, newValue in
					do {
						if newValue {
							try loginItems.register()
						} else {
							try loginItems.unregister()
						}
					} catch {
						// Registrierung fehlgeschlagen — Toggle zeigt den tatsächlichen Status.
						launchAtLogin = loginItems.isRegistered()
					}
				}

			LabeledContent("Ein-/Ausblenden") {
				VStack(alignment: .leading, spacing: 2) {
					if controller.isHotKeyRegistered {
						Text(GlobalHotKey.displayName)
					} else {
						Text("\(GlobalHotKey.displayName) — bereits belegt")
							.foregroundStyle(.red)
					}
					// Sonst findet die Geste niemand.
					Text("⌥-Klick aufs Symbol zeigt auch „Immer versteckt“")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			LabeledContent("Bedienungshilfen") {
				if isAccessibilityTrusted {
					Label("Erteilt", systemImage: "checkmark.circle.fill")
						.foregroundStyle(.green)
				} else {
					Button("Berechtigung erteilen…") {
						AccessibilityPermission.requestAccess()
					}
				}
			}
		}
		.padding()
		// ponytail: Status wird nur beim Öffnen geprüft, nicht live während das Fenster
		// offen bleibt. Erneutes Öffnen der Einstellungen reicht zum Auffrischen.
		.onAppear { isAccessibilityTrusted = AccessibilityPermission.isTrusted }
	}
}

private struct ItemsSettingsTab: View {
	let controller: MenuBarController

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let lastError = controller.lastError {
				Text(lastError)
					.foregroundStyle(.red)
					.font(.caption)
			}
			if controller.items.isEmpty {
				Text("Keine Menüleisten-Items gefunden.")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List(controller.items, id: \.storageKey) { item in
					HStack {
						Text(item.displayName)
						Spacer()
						Picker("", selection: sectionBinding(for: item)) {
							Text("Sichtbar").tag(MenuBarLayout.Section.visible)
							Text("Versteckt").tag(MenuBarLayout.Section.hidden)
							Text("Immer versteckt").tag(MenuBarLayout.Section.alwaysHidden)
						}
						.labelsHidden()
						.frame(width: 160)
					}
				}
			}
		}
		.padding()
	}

	private func sectionBinding(for item: MenuBarItem) -> Binding<MenuBarLayout.Section> {
		Binding(
			get: { controller.layout.section(of: item.storageKey) ?? .visible },
			set: { controller.moveItem(item.storageKey, to: $0) }
		)
	}
}

#Preview {
	SettingsView(controller: MenuBarController())
}
