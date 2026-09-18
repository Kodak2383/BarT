import AppKit
import Carbon.HIToolbox
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
			// The titles read while the permission was missing are wrong for good; only a
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
							// Registration failed; the toggle shows the actual state.
							launchAtLogin = loginItems.isRegistered()
						}
					}

			}

			Section("Revealing hidden items") {
				LabeledContent("Keyboard shortcut") {
					ShortcutRecorder(controller: controller)
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
	/// nothing on screen to explain what it is asking for. Per launch once, because macOS shows the
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
				// Measured 2026-09-17: without this permission there is neither an icon to
				// capture nor a `kCGWindowName` to read, so the grid falls back to names that
				// say "Control Center" twelve times over. Saying so beats showing it silently.
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Label(
						"The icons need the screen recording permission. Without it macOS hands out neither them nor the names, and every item reports its hosting app.",
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
				// Read-only (PRD §3.3): the grid shows where items sit, it does not move them.
				// Arranging is the user's own ⌘-drag in the menu bar, which BT-16 explains,
				// hence no picker, no menu and no drop target anywhere below.
				ScrollView {
					VStack(alignment: .leading, spacing: 18) {
						Label(
							// Measured on the live bar: a plain reveal expands only the first
							// separator, so the second ‹ is not on screen until ⌥-click.
							"The ‹ separators only appear while the hidden items are revealed. "
								+ "Click BarT's icon first, ⌥-click to bring out the second "
								+ "separator too, then ⌘-drag.",
							systemImage: "hand.draw"
						)
						.font(.callout)
						.foregroundStyle(.secondary)
						ForEach(MenuBarSection.allCases, id: \.self) { section in
							grid(for: section)
						}
					}
					.padding(16)
					.frame(maxWidth: .infinity, alignment: .leading)
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

	/// One section: its name, its items as a grid that wraps, and the sentence that says how the
	/// section is reached.
	private func grid(for section: MenuBarSection) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(Self.title(of: section))
				.font(.headline)
			let sectionItems = items(in: section)
			if sectionItems.isEmpty {
				// An empty section keeps its area: three areas that stay put are what makes the
				// window a picture of the bar rather than a list that reshuffles.
				Text("Empty")
					.font(.callout)
					.foregroundStyle(.tertiary)
					.frame(maxWidth: .infinity, minHeight: Self.cellHeight, alignment: .leading)
			} else {
				// `.adaptive` is the wrap: as many cells per row as fit, the rest on the next
				// one, and never a horizontal scroller (R4-Q1).
				LazyVGrid(
					columns: [GridItem(.adaptive(minimum: Self.cellWidth), spacing: 6)],
					alignment: .leading, spacing: 6
				) {
					ForEach(sectionItems, id: \.windowID) { item in
						cell(for: item)
					}
				}
			}
			Text(Self.explanation(of: section))
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}

	/// Wide enough for the items that are text instead of a glyph: a clock or a network meter
	/// is about twice as wide as it is tall.
	private static let cellWidth: CGFloat = 54
	private static let cellHeight: CGFloat = 24

	private func cell(for item: MenuBarItem) -> some View {
		let icon = controller.icons.icon(for: item.windowID)
		return Group {
			if let icon {
				Image(nsImage: icon)
					.resizable()
					.aspectRatio(contentMode: .fit)
			} else {
				// No capture: the name is all there is. On the plain background rather than on
				// the chip, because the chip is the menu bar's colour and text on it would be
				// the same white-on-white the icons would have been.
				Text(item.displayName)
					.font(.caption2)
					.lineLimit(1)
					.truncationMode(.middle)
					.foregroundStyle(.secondary)
			}
		}
		.padding(.horizontal, 4)
		.frame(width: Self.cellWidth, height: Self.cellHeight)
		.background {
			if icon != nil {
				RoundedRectangle(cornerRadius: 5)
					.fill(Color(nsColor: controller.icons.menuBarTint ?? .windowBackgroundColor))
			}
		}
		// The icon is a picture of a name nobody wrote down. Without this the grid is silent to
		// VoiceOver, and the tooltip answers the same question with the mouse.
		.help(item.displayName)
		.accessibilityElement(children: .ignore)
		.accessibilityAddTraits(.isImage)
		.accessibilityLabel(item.displayName)
	}

	private static func title(of section: MenuBarSection) -> String {
		switch section {
		case .visible: "Visible"
		case .hidden: "Hidden"
		case .alwaysHidden: "Always hidden"
		}
	}

	/// Says how the section is reached *and* how an item gets into it. The gesture belongs
	/// next to the thing it changes, not in a help page (BT-16). Every sentence names the ‹
	/// separator, because that is what the user is aiming at and they have never seen one.
	private static func explanation(of section: MenuBarSection) -> String {
		switch section {
		case .visible:
			"Always in the menu bar. ⌘-drag an item right past both ‹ separators to bring it back here."
		case .hidden:
			"Revealed by clicking the BarT icon or pressing \(GlobalHotKey.displayName). "
				+ "⌘-drag an item left past the first ‹ separator to move it here."
		case .alwaysHidden:
			"Only revealed on ⌥-click. ⌘-drag an item left past both ‹ separators to move it here."
		}
	}

}

/// Click, press a combination, done (BT-11).
///
/// The keystrokes are read with a *local* event monitor: it sees only what is aimed at this
/// window, the one the user just clicked, and swallows it. A global monitor would want the
/// accessibility permission BT-15 got rid of, for a field that is live for two seconds. BarT
/// installs no main menu, so there are no key equivalents to race against either.
private struct ShortcutRecorder: View {
	let controller: MenuBarController

	@State private var combination = GlobalHotKey.current
	@State private var isRecording = false
	@State private var monitor: Any?
	@State private var message: String?

	var body: some View {
		VStack(alignment: .trailing, spacing: 4) {
			HStack(spacing: 8) {
				if combination != GlobalHotKey.defaultCombination {
					Button("Reset") { apply(GlobalHotKey.defaultCombination) }
				}
				Button(isRecording ? "Press a combination…" : combination.displayName) {
					if isRecording { stopRecording() } else { startRecording() }
				}
				.monospaced(!isRecording)
				.frame(minWidth: 130)
			}
			Group {
				if let message {
					// The refusal, in the user's words; the old shortcut still works.
					Text(message)
						.foregroundStyle(.red)
				} else if isRecording {
					Text("⎋ cancels.")
						.foregroundStyle(.secondary)
				} else if !controller.isHotKeyRegistered {
					Text("Not registered. Another app is holding it.")
						.foregroundStyle(.red)
				}
			}
			.font(.caption)
			.multilineTextAlignment(.trailing)
			.fixedSize(horizontal: false, vertical: true)
		}
		// A recorder left listening would swallow the next keystroke in the whole app.
		.onDisappear(perform: stopRecording)
	}

	private func startRecording() {
		message = nil
		isRecording = true
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			MainActor.assumeIsolated {
				if event.keyCode == UInt16(kVK_Escape) {
					stopRecording()
				} else {
					stopRecording()
					apply(GlobalHotKey.combination(from: event))
				}
			}
			// Swallowed either way: while recording, a keystroke belongs to the recorder.
			return nil
		}
	}

	private func apply(_ candidate: GlobalHotKey.Combination) {
		if let failure = controller.setHotKey(candidate) {
			message = failure
		} else {
			combination = candidate
			message = nil
		}
	}

	private func stopRecording() {
		isRecording = false
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
	}
}

#Preview {
	SettingsView(controller: MenuBarController())
}
