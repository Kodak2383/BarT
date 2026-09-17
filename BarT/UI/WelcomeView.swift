import SwiftUI

/// What the first launch has to get across, in the order it matters.
///
/// BarT places an icon and otherwise does nothing visible, so without this window the first
/// impression is an app that did not start. Two things have to land: that it hides items, and
/// that *arranging* them is a gesture macOS has always had and almost nobody knows (PRD §3.2) —
/// an app that relies on a gesture has to teach it, or it looks broken.
///
/// Asks for no permission at all. The one BarT still needs belongs to the view that uses it
/// (BT-03), and a dialog on top of a window nobody has read yet explains nothing.
struct WelcomeView: View {
	let onDone: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Welcome to BarT")
					.font(.title2.weight(.semibold))
				Text("Your menu bar, as long or as short as you want it.")
					.foregroundStyle(.secondary)
			}

			step(
				"chevron.right.2",
				"BarT splits your menu bar in three",
				"Everything left of BarT's icon is out of sight until you ask for it. Click the "
					+ "icon or press \(GlobalHotKey.displayName) to bring it back for a moment; "
					+ "⌥-click also reveals what you told BarT to keep away for good."
			)
			step(
				"hand.draw",
				"You decide what goes where",
				"Hold ⌘ and drag an item along the menu bar, past one of BarT's two separators — "
					+ "the small ‹ markers. They only show while the hidden items are revealed, so "
					+ "click BarT's icon first — ⌥-click brings out the second separator too. macOS has always allowed this gesture and "
					+ "remembers where you put things; BarT shows you the result, it never moves "
					+ "an item itself.",
				illustration: gestureIllustration
			)
			step(
				"exclamationmark.shield",
				"Every update asks again",
				"BarT is not signed, so macOS treats each new version as a new app and forgets "
					+ "what you allowed the old one. Only one permission is involved: screen "
					+ "recording, asked for the first time you open the Items tab, and only to "
					+ "read the icons of your items."
			)

			HStack {
				Spacer()
				Button("Get started", action: onDone)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(24)
		.frame(width: 460)
	}

	private func step<Illustration: View>(
		_ symbol: String, _ title: String, _ body: String,
		@ViewBuilder illustration: () -> Illustration = { EmptyView() }
	) -> some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: symbol)
				.font(.title3)
				.foregroundStyle(.tint)
				.frame(width: 24)
				// The symbol repeats what the heading says; saying it twice is noise.
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 6) {
				Text(title)
					.font(.headline)
				Text(body)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				illustration()
			}
		}
	}

	/// The menu bar in miniature, with an item on its way across a separator.
	///
	/// The one thing in this window a sentence cannot carry on its own: the reader has never
	/// seen the separators, so "drag it past the separator" needs a picture of what they are
	/// aiming at. Drawn rather than captured — a screenshot of this would be three grey smudges
	/// and would go stale with the next appearance change.
	@ViewBuilder
	private func gestureIllustration() -> some View {
		VStack(alignment: .leading, spacing: 5) {
			HStack(spacing: 7) {
				chip()
				separatorMark
				chip()
				chip()
				chip(isMoving: true)
			}
			.padding(.horizontal, 9)
			.padding(.vertical, 5)
			.background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))

			HStack(spacing: 5) {
				Text("⌘")
					.fontWeight(.semibold)
				Image(systemName: "arrow.left")
				Text("hidden")
				Spacer(minLength: 12)
				Text("visible")
			}
			.font(.caption2)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 9)
		}
		.frame(width: 190)
		// The sentence above says all of this; a screen reader reading it twice learns nothing.
		.accessibilityHidden(true)
	}

	private var separatorMark: some View {
		Image(systemName: "chevron.compact.left")
			.font(.caption)
			.foregroundStyle(.tint)
	}

	private func chip(isMoving: Bool = false) -> some View {
		RoundedRectangle(cornerRadius: 3)
			.fill(isMoving ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
			.frame(width: 16, height: 11)
	}
}

#Preview {
	WelcomeView(onDone: {})
}
