import SwiftUI

struct SettingsView: View {
	let controller: MenuBarController

	var body: some View {
		TabView {
			GeneralSettingsTab(controller: controller)
				.tabItem {
					Label("General", systemImage: "gear")
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
			Toggle("Launch at login", isOn: $launchAtLogin)
				.onChange(of: launchAtLogin) { _, newValue in
					do {
						if newValue {
							try loginItems.register()
						} else {
							try loginItems.unregister()
						}
					} catch {
						// Registration failed — the toggle shows the actual state.
						launchAtLogin = loginItems.isRegistered()
					}
				}

			LabeledContent("Show/Hide") {
				VStack(alignment: .leading, spacing: 2) {
					if controller.isHotKeyRegistered {
						Text(GlobalHotKey.displayName)
					} else {
						Text("\(GlobalHotKey.displayName) — already taken")
							.foregroundStyle(.red)
					}
					// Nobody would ever find this gesture otherwise.
					Text("⌥-click the icon to reveal “Always hidden” as well")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			LabeledContent("Accessibility") {
				if isAccessibilityTrusted {
					Label("Granted", systemImage: "checkmark.circle.fill")
						.foregroundStyle(.green)
				} else {
					Button("Grant permission…") {
						AccessibilityPermission.requestAccess()
					}
				}
			}
		}
		.padding()
		// ponytail: the status is only checked when the window opens, not live while it
		// stays open. Reopening Settings is enough to refresh it.
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
				Text("No menu bar items found.")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List(controller.items, id: \.storageKey) { item in
					HStack {
						Text(item.displayName)
						Spacer()
						Picker("", selection: sectionBinding(for: item)) {
							Text("Visible").tag(MenuBarLayout.Section.visible)
							Text("Hidden").tag(MenuBarLayout.Section.hidden)
							Text("Always hidden").tag(MenuBarLayout.Section.alwaysHidden)
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
