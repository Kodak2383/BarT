import AppKit
import OSLog
import ScreenCaptureKit

/// The real icon of every menu bar item, captured from the item's own window.
///
/// Since BT-15 the view is read-only, so an icon the user recognises is all the identification
/// that is left, and it is the only one that works: measured 2026-09-17, nine of twenty-one
/// items hand out no window title at all, and every one of them falls back to "Control Center".
///
/// One pass per list rather than one call per item: ``SCShareableContent`` is the expensive part
/// (a round trip to the window server), the per-window capture after it is cheap. Cached per
/// window ID, so the two-second poll never triggers a capture (PRD §3.2).
@MainActor
@Observable
final class ItemIconSource {
	private(set) var icons: [CGWindowID: NSImage] = [:]

	/// What the menu bar itself looks like behind its items, sampled once per pass.
	///
	/// The bar is translucent: with a dark desktop picture it goes dark under a light system
	/// appearance, and macOS then draws every glyph white, which is invisible on the settings
	/// window's background. The icons sit on a chip of this colour instead, the way they sit in
	/// the bar.
	private(set) var menuBarTint: NSColor?

	/// Window IDs that were in the list but produced no image, remembered so a pass does not
	/// retry them forever. Cleared with the cache.
	private var failed: Set<CGWindowID> = []

	/// Set by ``resampleTintOnNextLoad()``, consumed by the next ``load(for:)``.
	private var tintNeedsResample = false

	private var isCapturing = false

	private let log = Logger(subsystem: "de.andreduhme.BarT", category: "ItemIconSource")

	func icon(for windowID: CGWindowID) -> NSImage? { icons[windowID] }

	/// Captures every icon that is not cached yet; a no-op once they all are.
	/// - Parameter items: only the ones currently on screen are attempted. A window that is not
	///   rendered has nothing to capture: ScreenCaptureKit answers with error -3811 (measured
	///   2026-09-17 on a hidden item), and a hidden item is pushed off to the left of the bar.
	///   Those get their turn from ``MenuBarController``, which runs a pass while the bar is
	///   revealed and they are briefly visible.
	func load(for items: [MenuBarItem]) async {
		let missing = items.filter {
			$0.isOnScreen && icons[$0.windowID] == nil && !failed.contains($0.windowID)
		}
		// The tint gets its own condition: once every icon is cached there is nothing missing,
		// and a re-sample asked for by a reopened window would otherwise never run.
		let needsTint = menuBarTint == nil || tintNeedsResample
		guard !missing.isEmpty || needsTint, !isCapturing, ScreenRecordingPermission.isGranted
		else { return }
		isCapturing = true
		defer { isCapturing = false }

		if needsTint {
			tintNeedsResample = false
			// Keep the old value on a failed sample rather than clearing it: the settings chip
			// would otherwise flash to no colour while the new sample is in flight.
			if let tint = await Self.sampleMenuBarTint() { menuBarTint = tint }
		}
		guard !missing.isEmpty else { return }

		let started = ContinuousClock.now
		var captured = 0
		do {
			// `onScreenWindowsOnly: false`: kept even though `missing` above already filters to
			// `isOnScreen` items, because whether ScreenCaptureKit's own on-screen notion lines
			// up exactly with `isOnScreen` was never measured. `true` might be cheaper; worth
			// trying if this pass ever shows up in a profile.
			let content = try await SCShareableContent.excludingDesktopWindows(
				false, onScreenWindowsOnly: false
			)
			let windows = Dictionary(
				content.windows.map { ($0.windowID, $0) },
				uniquingKeysWith: { first, _ in first }
			)
			for item in missing {
				guard let window = windows[item.windowID], let image = await Self.capture(window)
				else {
					failed.insert(item.windowID)
					continue
				}
				icons[item.windowID] = image
				captured += 1
			}
		} catch {
			// Denied, revoked mid-session, or the window vanished. The list keeps working and
			// shows names only.
			log.error("icon pass failed: \(error.localizedDescription)")
		}
		log.info(
			"""
			icon pass: \(captured, privacy: .public) of \(missing.count, privacy: .public) \
			in \(started.duration(to: .now).description, privacy: .public)
			"""
		)
	}

	/// Throws away everything: after the screen recording permission changed, the cached
	/// failures are all stale.
	func reset() {
		icons.removeAll()
		failed.removeAll()
		menuBarTint = nil
	}

	/// Drops cached icons and failures for window IDs that are no longer in the list. Hidden
	/// items are still in that list (``MenuBarItemSource`` enumerates them too), so their icons
	/// survive; only windows that vanished for good are forgotten.
	func forget(allBut ids: Set<CGWindowID>) {
		icons = icons.filter { ids.contains($0.key) }
		failed.formIntersection(ids)
	}

	/// Marks the tint stale without clearing it, so the next ``load(for:)`` samples again
	/// (the settings window just reopened) without the chip flashing to no colour in between.
	func resampleTintOnNextLoad() {
		tintNeedsResample = true
	}

	/// The menu bar's backdrop, read from a strip in the middle of the bar. The app menus end
	/// well to its left and the status items start well to its right, so what is left there is
	/// the bar itself.
	private static func sampleMenuBarTint() async -> NSColor? {
		// The strip rect below uses y=1 in global coordinates, which is the primary display's
		// menu bar, not whichever screen `.main` happens to be (the one with the key window).
		guard let screen = NSScreen.screens.first else { return nil }
		let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
		guard barHeight > 2 else { return nil }
		let strip = CGRect(x: screen.frame.midX, y: 1, width: 40, height: barHeight - 2)
		guard let image = try? await SCScreenshotManager.captureImage(in: strip) else { return nil }
		// Averaging by drawing into a single pixel, the cheapest mean there is, and the
		// gradient across the bar is exactly what should be averaged away.
		var pixel: [UInt8] = [0, 0, 0, 0]
		guard
			let context = CGContext(
				data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { return nil }
		context.interpolationQuality = .medium
		context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
		return NSColor(
			srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
			blue: CGFloat(pixel[2]) / 255, alpha: 1
		)
	}

	private static func capture(_ window: SCWindow) async -> NSImage? {
		let filter = SCContentFilter(desktopIndependentWindow: window)
		let configuration = SCStreamConfiguration()
		// Points to pixels by hand: the default output is the content size in *points*, which on
		// a Retina display is a 22 px thumbnail of a 44 px icon.
		// A window thousands of points wide is one of BarT's own collapsed separators, not an
		// icon, and capturing it would allocate an image twenty thousand pixels across.
		guard filter.contentRect.width < 512 else { return nil }
		let scale = CGFloat(filter.pointPixelScale)
		configuration.width = Int(filter.contentRect.width * scale)
		configuration.height = Int(filter.contentRect.height * scale)
		configuration.showsCursor = false
		configuration.ignoreShadowsSingleWindow = true
		guard
			configuration.width > 0, configuration.height > 0,
			let image = try? await SCScreenshotManager.captureImage(
				contentFilter: filter, configuration: configuration
			)
		else { return nil }
		// Left exactly as captured, colours and all. A template image would be one line shorter
		// and legible in any appearance, but it throws the colour away: the two temperature
		// items turn into solid black pills (tried, 2026-09-17). The chip behind the icon does
		// the same job without lying about the pixels.
		return NSImage(cgImage: image, size: filter.contentRect.size)
	}
}

// MARK: - Self-test

extension ItemIconSource {
	/// Captures the live bar once and reports how many items gave up an icon and what the pass
	/// cost, the number BT-06 asks to be measured, and the only way to see that a change to the
	/// capture path still captures anything.
	@discardableResult
	func runIconSelfTest() async -> Bool {
		guard ScreenRecordingPermission.isGranted else {
			print("[BarT] Icon self-test skipped: no screen recording permission")
			return true
		}
		let items = MenuBarItemSource.enumerate()
		let started = ContinuousClock.now
		await load(for: items)
		let elapsed = started.duration(to: .now)
		guard !icons.isEmpty else {
			print("[BarT] Icon self-test FAILED: \(items.count) items, not one icon captured")
			return false
		}
		print(
			"[BarT] Icon self-test: \(icons.count) of \(items.count) icons in \(elapsed)"
		)
		return true
	}
}
