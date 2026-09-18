import AppKit
import CoreGraphics

/// The one permission BarT still needs after BT-15. It is not only about capturing pixels:
/// measured 2026-09-17, macOS withholds `kCGWindowName` without it, so every menu bar item
/// reports its hosting process and the items view reads "Control Center" twenty-one times.
///
/// BarT is unsigned, so TCC ties the grant to a signature that changes on every rebuild, so
/// the state has to be read fresh, never cached across an app activation.
enum ScreenRecordingPermission {
	static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

	/// Shows the system prompt. macOS shows it only once per app identity; afterwards this
	/// returns the standing answer without any UI, which is why the views always offer the
	/// system settings as well.
	@discardableResult
	static func request() -> Bool { CGRequestScreenCaptureAccess() }

	static func openSystemSettings() {
		let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
		)!
		NSWorkspace.shared.open(url)
	}
}
