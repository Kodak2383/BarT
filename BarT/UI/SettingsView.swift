import CoreGraphics
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
			if !CGPreflightScreenCaptureAccess() {
				// Measured 2026-09-17: without this permission macOS withholds `kCGWindowName`,
				// so every item falls back to its hosting app and the list reads "Control
				// Center" twenty-one times. Saying so beats showing it silently. BT-03 turns
				// this into a request, BT-06 replaces the names with the real icons.
				Label(
					"Item names need the screen recording permission — without it macOS reports every item as its hosting app.",
					systemImage: "info.circle"
				)
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
					description: Text("BarT could not read the menu bar.")
				)
			} else {
				// Read-only (PRD §3.3): the view shows where items sit, it does not move them.
				// Arranging is the user's own ⌘-drag in the menu bar — BT-16 explains the
				// gesture properly, this is the placeholder until then.
				List {
					ForEach(MenuBarSection.allCases, id: \.self) { section in
						Section {
							let sectionItems = items(in: section)
							if sectionItems.isEmpty {
								Text("Empty")
									.font(.callout)
									.foregroundStyle(.tertiary)
							} else {
								ForEach(sectionItems, id: \.windowID) { item in
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
	private func items(in section: MenuBarSection) -> [MenuBarItem] {
		controller.items.filter { controller.section(of: $0) == section }
	}

	private func row(for item: MenuBarItem) -> some View {
		Text(item.displayName)
			.lineLimit(1)
			.truncationMode(.middle)
			.padding(.vertical, 2)
	}

	private static func title(of section: MenuBarSection) -> String {
		switch section {
		case .visible: "Visible"
		case .hidden: "Hidden"
		case .alwaysHidden: "Always hidden"
		}
	}

	private static func explanation(of section: MenuBarSection) -> String {
		switch section {
		case .visible: "Always in the menu bar."
		case .hidden: "Revealed by clicking the BarT icon or pressing \(GlobalHotKey.displayName)."
		case .alwaysHidden: "Only revealed on ⌥-click."
		}
	}

}

#Preview {
	SettingsView(controller: MenuBarController())
}
