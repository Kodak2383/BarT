import AppKit
import SwiftUI

struct SettingsView: View {
	let controller: MenuBarController

	/// Read once here and re-read on every activation instead of in each tab: the user grants
	/// the permission in System Settings, so the answer only ever changes while BarT is in the
	/// background. `onAppear` alone would show a state that went stale the moment they left.
	@State private var hasScreenRecording = ScreenRecordingPermission.isGranted

	var body: some View {
		TabView {
			GeneralSettingsTab(controller: controller, hasScreenRecording: $hasScreenRecording)
				.tabItem {
					Label("General", systemImage: "gear")
				}
			ItemsSettingsTab(controller: controller, hasScreenRecording: $hasScreenRecording)
				.tabItem {
					Label("Items", systemImage: "menubar.rectangle")
				}
		}
		.frame(minWidth: 460, minHeight: 400)
		.onReceive(
			NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
		) { _ in
			let granted = ScreenRecordingPermission.isGranted
			guard granted != hasScreenRecording else { return }
			hasScreenRecording = granted
			// The titles read while the permission was missing are wrong for good — only a
			// fresh enumeration carries the real names.
			controller.refresh()
		}
	}
}

private struct GeneralSettingsTab: View {
	let controller: MenuBarController

	@Binding var hasScreenRecording: Bool

	private let loginItems = LoginItemManager()

	@State private var launchAtLogin: Bool

	init(controller: MenuBarController, hasScreenRecording: Binding<Bool>) {
		self.controller = controller
		_hasScreenRecording = hasScreenRecording
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

			Section("Permission") {
				LabeledContent("Screen recording") {
					HStack(spacing: 8) {
						if hasScreenRecording {
							Label("Granted", systemImage: "checkmark.circle.fill")
								.foregroundStyle(.green)
						} else {
							Label("Not granted", systemImage: "exclamationmark.circle.fill")
								.foregroundStyle(.orange)
						}
						Button("Open System Settings…") {
							ScreenRecordingPermission.openSystemSettings()
						}
					}
					.font(.callout)
				}
				Text(
					"BarT reads the names of your menu bar items, which macOS only hands out "
						+ "with this permission. It never records your screen."
				)
				.font(.caption)
				.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}
}

private struct ItemsSettingsTab: View {
	let controller: MenuBarController

	@Binding var hasScreenRecording: Bool

	/// The prompt belongs to the first look at the items, not to launch: at launch BarT has
	/// nothing on screen to explain what it is asking for. Per launch once — macOS shows the
	/// dialog only the first time anyway, and a silent no-op on every tab switch is noise.
	@MainActor private static var didRequestThisLaunch = false

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
			if !hasScreenRecording {
				// Measured 2026-09-17: without this permission macOS withholds `kCGWindowName`,
				// so every item falls back to its hosting app and the list reads "Control
				// Center" twenty-one times. Saying so beats showing it silently — BT-06
				// replaces the names with the real icons.
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Label(
						"Item names need the screen recording permission — without it macOS reports every item as its hosting app.",
						systemImage: "info.circle"
					)
					.frame(maxWidth: .infinity, alignment: .leading)
					Button("Allow…") {
						// Returns the standing answer without UI once macOS has asked; the
						// system settings are the way back from a denial.
						if !ScreenRecordingPermission.request() {
							ScreenRecordingPermission.openSystemSettings()
						}
					}
				}
				.font(.callout)
				.foregroundStyle(.secondary)
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
		.task {
			guard !hasScreenRecording, !Self.didRequestThisLaunch else { return }
			Self.didRequestThisLaunch = true
			hasScreenRecording = ScreenRecordingPermission.request()
		}
		.task(id: iconPass) {
			await controller.icons.load(for: controller.items)
		}
	}

	/// What a capture pass depends on. Empty while the permission is missing, so granting it
	/// starts a pass instead of leaving the list on the names it opened with.
	private var iconPass: [CGWindowID] {
		hasScreenRecording ? controller.items.map(\.windowID) : []
	}

	/// Items of one section, in the order they physically sit in the bar (left to right).
	private func items(in section: MenuBarSection) -> [MenuBarItem] {
		controller.items.filter { controller.section(of: $0) == section }
	}

	private func row(for item: MenuBarItem) -> some View {
		HStack(spacing: 8) {
			if hasScreenRecording {
				// A fixed box whether or not the capture worked, so the names stay in one
				// column. Wide enough for the items that are text rather than a glyph — a
				// clock's window is about twice as wide as it is tall.
				Group {
					if let icon = controller.icons.icon(for: item.windowID) {
						Image(nsImage: icon)
							.resizable()
							.aspectRatio(contentMode: .fit)
					} else {
						Image(systemName: "square.dashed")
							.foregroundStyle(.tertiary)
					}
				}
				.frame(width: 44, height: 18)
				.padding(.horizontal, 3)
				.padding(.vertical, 2)
				.background(
					RoundedRectangle(cornerRadius: 5)
						.fill(Color(nsColor: controller.icons.menuBarTint ?? .windowBackgroundColor))
				)
			}
			Text(item.displayName)
				.lineLimit(1)
				.truncationMode(.middle)
		}
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
