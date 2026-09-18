import AppKit
import CoreGraphics

/// Runtime identity of a menu bar item.
///
/// Valid within a single session only: `windowID` and `ownerPID` both change as soon as the
/// owning app restarts. Nothing here is persisted: which section an item belongs to is read from
/// where it sits relative to the separators, and macOS remembers that arrangement itself.
struct MenuBarItemID: Hashable, Sendable {
	let windowID: CGWindowID

	/// The *hosting* process for Apple's own items. macOS renders menu extras out of process,
	/// so all of them report Control Center. Determining the true owner needed the accessibility
	/// permission, which BarT no longer asks for; see ``displayName`` for the consequence.
	let ownerPID: pid_t

	/// Bundle ID of the hosting app, or its process name as a fallback.
	let bundleID: String

	/// The item's window title, from `kCGWindowName`: "WiFi", "Clock", "CPU_mini". Measured on
	/// macOS 26: this needs the screen recording permission, and several of Apple's own extras
	/// leave it empty even then.
	let title: String

	/// What the items view shows.
	///
	/// The title comes first, deliberately. Since the owner lookup went away with the drag
	/// engine, the app name is the hosting process for every one of Apple's menu extras, and eight
	/// rows of "Control Center" say less than "WiFi", "Battery", "Clock".
	var displayName: String {
		// Titles like "Item-0" are placeholders an app never meant as a name.
		let named = title.hasPrefix("Item-") ? "" : Self.humanized(title)
		if !named.isEmpty { return named }
		return NSRunningApplication(processIdentifier: ownerPID)?.localizedName ?? bundleID
	}

	/// Window titles are written for the app itself, not for a list a person reads. Measured on
	/// the live bar 2026-09-17: `com.apple.menuextra.TimeMachine`, `Battery_battery_details`,
	/// `BentoBox-0`.
	///
	/// Deliberately conservative: it only touches the three shapes that are demonstrably an
	/// internal key, and leaves every name an app chose for itself alone. Splitting camel case
	/// everywhere would turn "WiFi" into "Wi Fi", which is worse than doing nothing.
	static func humanized(_ title: String) -> String {
		var name = title

		// Apple's extras carry the raw identifier. Camel case is safe on this branch: these are
		// dotted identifiers, where the capital always starts a new word.
		if name.hasPrefix("com.apple."), let identifier = name.split(separator: ".").last {
			name = splittingCamelCase(String(identifier))
		}

		// An internal key, underscores and all: "Battery_battery_details".
		name = name.replacingOccurrences(of: "_", with: " ")

		// A trailing index numbers the window, it is not part of the name: "BentoBox-0".
		if let dash = name.lastIndex(of: "-"), dash != name.startIndex,
			name[name.index(after: dash)...].allSatisfy(\.isNumber) {
			name = String(name[..<dash])
		}

		// Those keys repeat the component name: "Battery battery details".
		var words: [String] = []
		for word in name.split(separator: " ") where words.last?.lowercased() != word.lowercased() {
			words.append(String(word))
		}
		return words.joined(separator: " ")
	}

	private static func splittingCamelCase(_ identifier: String) -> String {
		identifier.reduce(into: "") { result, character in
			if character.isUppercase, let previous = result.last, previous.isLowercase {
				result.append(" ")
			}
			result.append(character)
		}
	}

	/// Table of the names the live bar actually produced, so a change to ``humanized`` that
	/// looks harmless has to survive them.
	@discardableResult
	static func runDisplayNameSelfTest() -> Bool {
		let cases = [
			("com.apple.menuextra.TimeMachine", "Time Machine"),
			("Battery_battery_details", "Battery details"),
			("Network_speed", "Network speed"),
			("CPU_mini", "CPU mini"),
			("BentoBox-0", "BentoBox"),
			// Names an app chose itself stay untouched; this is the regression that matters.
			("WiFi", "WiFi"),
			("Clock", "Clock"),
			("VorssaintMenuBarItem", "VorssaintMenuBarItem"),
		]
		let failures = cases.filter { humanized($0.0) != $0.1 }
		for (input, expected) in failures {
			print("[BarT] Display-name self-test FAILED: \(input) → \(humanized(input)), want \(expected)")
		}
		if failures.isEmpty {
			print("[BarT] Display-name self-test: \(cases.count) names cleaned up as expected")
		}
		return failures.isEmpty
	}
}

/// A menu bar item together with its current geometry.
struct MenuBarItem: Hashable, Sendable {
	let id: MenuBarItemID

	/// Global CG coordinates (origin top left), see ``CGSBridge/frame(for:)``.
	let frame: CGRect

	/// `false` once the item has been pushed out of the visible area, that is, exactly when a
	/// separator hides it.
	let isOnScreen: Bool

	var windowID: CGWindowID { id.windowID }
	var ownerPID: pid_t { id.ownerPID }
	var displayName: String { id.displayName }
}
