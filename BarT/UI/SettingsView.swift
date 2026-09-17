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
		.frame(minWidth: 460, minHeight: 400)
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
		// `.grouped` is what System Settings itself uses: content starts at the top instead of
		// floating in the middle of the window, and each row sits in its own panel.
		Form {
			Section {
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
			} footer: {
				if !isAccessibilityTrusted {
					// Without this the app looks broken rather than unauthorized: items still
					// appear, but all of them under the wrong owner.
					Text("Without this permission items cannot be moved, and they all show up as belonging to Control Center.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			Section("Revealing hidden items") {
				LabeledContent("Keyboard shortcut") {
					if controller.isHotKeyRegistered {
						Text(GlobalHotKey.displayName)
							.monospaced()
					} else {
						Text("\(GlobalHotKey.displayName) — already taken")
							.foregroundStyle(.red)
					}
				}
				LabeledContent("Click the menu bar icon") {
					VStack(alignment: .leading, spacing: 2) {
						Text("Shows the hidden items")
						// Nobody would ever find this gesture otherwise.
						Text("⌥-click shows “Always hidden” as well")
							.foregroundStyle(.secondary)
					}
					.font(.callout)
				}
			}
		}
		.formStyle(.grouped)
		// ponytail: the status is only checked when the window opens, not live while it
		// stays open. Reopening Settings is enough to refresh it.
		.onAppear { isAccessibilityTrusted = AccessibilityPermission.isTrusted }
	}
}

private struct ItemsSettingsTab: View {
	let controller: MenuBarController

	var body: some View {
		VStack(spacing: 0) {
			if let lastError = controller.lastError {
				Label(lastError, systemImage: "exclamationmark.triangle.fill")
					.font(.callout)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(10)
					.background(.quaternary)
			}
			if controller.items.isEmpty {
				ContentUnavailableView(
					"No menu bar items found",
					systemImage: "menubar.rectangle",
					description: Text("BarT could not read the menu bar. Check the accessibility permission under General.")
				)
			} else {
				// Grouped by section rather than one flat list: the whole point of the window is
				// seeing what ends up where, and with a picker per row that took reading every
				// single line.
				List {
					ForEach(MenuBarLayout.Section.allCases, id: \.self) { section in
						Section {
							let sectionItems = items(in: section)
							if sectionItems.isEmpty {
								Text("Empty")
									.font(.callout)
									.foregroundStyle(.tertiary)
							} else {
								ForEach(sectionItems, id: \.storageKey) { item in
									row(for: item)
								}
							}
						} header: {
							Text(Self.title(of: section))
						} footer: {
							Text(Self.explanation(of: section))
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				}
			}
		}
	}

	/// Items of one section, in the order they physically sit in the bar (left to right).
	private func items(in section: MenuBarLayout.Section) -> [MenuBarItem] {
		controller.items.filter { controller.layout.section(of: $0.storageKey) ?? .visible == section }
	}

	private func row(for item: MenuBarItem) -> some View {
		HStack {
			Text(item.displayName)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 12)
			Picker("", selection: sectionBinding(for: item)) {
				Text("Visible").tag(MenuBarLayout.Section.visible)
				Text("Hidden").tag(MenuBarLayout.Section.hidden)
				Text("Always hidden").tag(MenuBarLayout.Section.alwaysHidden)
			}
			.labelsHidden()
			.frame(width: 150)
		}
		.padding(.vertical, 2)
	}

	private static func title(of section: MenuBarLayout.Section) -> String {
		switch section {
		case .visible: "Visible"
		case .hidden: "Hidden"
		case .alwaysHidden: "Always hidden"
		}
	}

	private static func explanation(of section: MenuBarLayout.Section) -> String {
		switch section {
		case .visible: "Always in the menu bar."
		case .hidden: "Revealed by clicking the BarT icon or pressing \(GlobalHotKey.displayName)."
		case .alwaysHidden: "Only revealed on ⌥-click."
		}
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
