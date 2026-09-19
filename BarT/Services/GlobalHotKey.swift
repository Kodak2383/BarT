import AppKit
import Carbon.HIToolbox

/// A system-wide registered key combination, exactly one at a time (R4-Q7); ⌥-reveal stays a
/// click gesture.
///
/// Deliberately built on the Carbon hotkey API rather than `NSEvent.addGlobalMonitorForEvents`:
/// a global keyboard monitor would see *every* keystroke the user makes, passwords included,
/// and would still pass the combination on to the frontmost app as well. `RegisterEventHotKey`
/// registers this one combination and swallows it.
///
/// Lives as long as the app does, hence no `deinit`, which would only ever run at quit.
@MainActor
final class GlobalHotKey {
	/// One key plus its modifiers, in the form Carbon wants them.
	struct Combination: Equatable, Sendable {
		let keyCode: UInt32

		/// Carbon's own mask (`controlKey`, `cmdKey`, …), *not* `NSEvent.ModifierFlags`.
		let carbonModifiers: UInt32

		/// What the key prints on *this* keyboard, taken from the event while recording.
		/// Translating a key code back would mean `UCKeyTranslate` plus the current input
		/// source; the event already knows, and on a German layout `kVK_ANSI_Y` prints "Z".
		let keyName: String

		/// In the order Apple prints them: ⌃⌥⇧⌘.
		var displayName: String {
			var name = ""
			if carbonModifiers & UInt32(controlKey) != 0 { name += "⌃" }
			if carbonModifiers & UInt32(optionKey) != 0 { name += "⌥" }
			if carbonModifiers & UInt32(shiftKey) != 0 { name += "⇧" }
			if carbonModifiers & UInt32(cmdKey) != 0 { name += "⌘" }
			return name + keyName
		}
	}

	/// ⌃⌥⌘B. Three modifiers, so it stays out of everyone's way.
	static let defaultCombination = Combination(
		keyCode: UInt32(kVK_ANSI_B),
		carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
		keyName: "B"
	)

	/// The combination in force. Static because three places name it in a sentence, the
	/// welcome window among them, and none of them has a controller to ask. There is one
	/// shortcut for the whole app anyway.
	private(set) static var current = loadFromDefaults() ?? defaultCombination

	static var displayName: String { current.displayName }

	private var hotKeyRef: EventHotKeyRef?
	private var eventHandler: EventHandlerRef?

	/// `false` if the combination is already taken or Carbon rejects it.
	private(set) var isRegistered = false

	init(action: @escaping @MainActor () -> Void) {
		registeredAction = action

		var eventType = EventTypeSpec(
			eventClass: OSType(kEventClassKeyboard),
			eventKind: UInt32(kEventHotKeyPressed)
		)
		guard InstallEventHandler(
			GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &eventHandler
		) == noErr else { return }

		// Whatever the user recorded last, or ⌃⌥⌘B. Not through ``register(_:)``: that one
		// writes to the defaults, and a first launch has nothing to write yet.
		_ = apply(Self.current)
	}

	/// Swaps the live registration and remembers the combination.
	///
	/// - Returns: `nil` on success, otherwise one sentence for the user, and the combination
	///   that worked before is the one still working.
	@discardableResult
	func register(_ combination: Combination) -> String? {
		if let refusal = Self.refusal(for: combination) { return refusal }
		let previous = Self.current
		if let failure = apply(combination) {
			// A rejected attempt must not leave the user with no shortcut at all.
			_ = apply(previous)
			return failure
		}
		Self.current = combination
		Self.save(combination)
		return nil
	}

	/// The Carbon half: unregister what is there, register what was asked for.
	private func apply(_ combination: Combination) -> String? {
		isRegistered = false
		if let hotKeyRef {
			UnregisterEventHotKey(hotKeyRef)
			self.hotKeyRef = nil
		}
		guard eventHandler != nil else { return "BarT could not attach to the keyboard." }
		// The signature is arbitrary, it only has to be unique within the app: "BTHK".
		let id = EventHotKeyID(signature: 0x4254_484B, id: 1)
		guard RegisterEventHotKey(
			combination.keyCode,
			combination.carbonModifiers,
			id,
			GetApplicationEventTarget(),
			0,
			&hotKeyRef
		) == noErr else {
			return "\(combination.displayName) is already taken by another app."
		}
		isRegistered = true
		return nil
	}

	/// Why this combination cannot be used, or `nil` if it can.
	///
	/// Two things Carbon does not say on its own. A combination without ⌃, ⌥ or ⌘ would swallow
	/// the bare key in every app the user types in. And a shortcut macOS has already claimed
	/// registers with `noErr` and then never fires, because the system sees the keystroke
	/// first, which is why this reads the system's own list instead of trusting the status.
	static func refusal(for combination: Combination) -> String? {
		guard combination.carbonModifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
			return "A shortcut needs ⌃, ⌥ or ⌘. Without one it would swallow "
				+ "\(combination.keyName) in every app."
		}
		guard !isSystemOwned(combination) else {
			return "\(combination.displayName) belongs to macOS. It can be freed in "
				+ "System Settings › Keyboard › Keyboard Shortcuts."
		}
		return nil
	}

	/// The combinations macOS reserved for itself, read from the same preference System
	/// Settings writes. Public API on a foreign domain, because BarT is not sandboxed.
	///
	/// ponytail: only the entries this list actually holds. An app-specific shortcut in another
	/// app, or a system one recorded under a key code of -1, still slips through and simply
	/// never fires. Widen it when somebody reports a shortcut that looks accepted and is not.
	private static func isSystemOwned(_ combination: Combination) -> Bool {
		guard
			let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
			let entries = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
		else { return false }
		let wanted = cocoaModifiers(from: combination.carbonModifiers)
		return entries.values.contains { entry in
			guard
				let entry = entry as? [String: Any],
				(entry["enabled"] as? NSNumber)?.boolValue == true,
				let value = entry["value"] as? [String: Any],
				let parameters = value["parameters"] as? [Int],
				parameters.count >= 3
			else { return false }
			// [character, virtual key code, modifier mask]. The character is 65535 wherever the
			// key code is what counts, which is every entry that can collide with ours.
			return parameters[1] == Int(combination.keyCode) && parameters[2] == wanted
		}
	}

	/// Reads a combination out of a recorded key event.
	static func combination(from event: NSEvent) -> Combination {
		Combination(
			keyCode: UInt32(event.keyCode),
			carbonModifiers: carbonModifiers(from: event.modifierFlags),
			keyName: keyName(for: event)
		)
	}

	static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
		var carbon: UInt32 = 0
		if flags.contains(.control) { carbon |= UInt32(controlKey) }
		if flags.contains(.option) { carbon |= UInt32(optionKey) }
		if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
		if flags.contains(.command) { carbon |= UInt32(cmdKey) }
		return carbon
	}

	/// What `AppleSymbolicHotKeys` stores: the raw value of `NSEvent.ModifierFlags`.
	private static func cocoaModifiers(from carbon: UInt32) -> Int {
		var flags: NSEvent.ModifierFlags = []
		if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
		if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
		if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
		if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
		return Int(flags.rawValue)
	}

	/// Keys that print nothing. Without these the field would show an invisible control
	/// character where the user expects to read their own shortcut back.
	private static let specialKeyNames: [Int: String] = [
		kVK_Space: "␣", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
		kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
		kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
	]

	private static func keyName(for event: NSEvent) -> String {
		if let special = specialKeyNames[Int(event.keyCode)] { return special }
		// Ignores every modifier but shift, so ⌥B still reads as "B" rather than "∫".
		guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
			return "Key \(event.keyCode)"
		}
		// The function keys arrive in the private-use area: NSF1FunctionKey is 0xF704.
		if (0xF704...0xF70F).contains(scalar.value) { return "F\(scalar.value - 0xF703)" }
		guard scalar.value > 0x20 else { return "Key \(event.keyCode)" }
		return String(scalar).uppercased()
	}
}

extension GlobalHotKey {
	/// Debug: the half of the shortcut that has no keyboard in it: how a combination is
	/// written down, how the two modifier masks convert, and what gets refused before Carbon
	/// ever sees it.
	@discardableResult
	static func runShortcutSelfTest() -> Bool {
		func combination(_ modifiers: Int, _ keyCode: Int, _ name: String) -> Combination {
			Combination(
				keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers), keyName: name
			)
		}
		var failures: [String] = []
		func check(_ passed: Bool, _ what: String) {
			if !passed { failures.append(what) }
		}

		check(defaultCombination.displayName == "⌃⌥⌘B", "the default reads ⌃⌥⌘B")
		check(
			combination(controlKey | optionKey | shiftKey | cmdKey, kVK_ANSI_A, "A").displayName
				== "⌃⌥⇧⌘A",
			"modifiers print in the order ⌃⌥⇧⌘"
		)
		check(
			carbonModifiers(from: [.command, .shift]) == UInt32(cmdKey | shiftKey),
			"NSEvent flags convert to the Carbon mask"
		)
		check(
			cocoaModifiers(from: UInt32(cmdKey)) == 1_048_576,
			"the Carbon mask converts to what AppleSymbolicHotKeys stores"
		)
		check(
			refusal(for: combination(0, kVK_ANSI_B, "B")) != nil,
			"a bare key is refused"
		)
		check(
			refusal(for: combination(shiftKey, kVK_ANSI_B, "B")) != nil,
			"⇧ alone is refused"
		)
		check(refusal(for: defaultCombination) == nil, "⌃⌥⌘B is allowed")

		for what in failures {
			print("[BarT] Shortcut self-test FAILED: \(what)")
		}
		if failures.isEmpty {
			// Environment, not an assertion: the list depends on what the user has configured,
			// and it is the one thing here worth seeing in the log.
			let spotlight = combination(cmdKey, kVK_Space, "␣")
			print(
				"[BarT] Shortcut self-test: 7 cases as expected, ⌘Space seen as taken by macOS: "
					+ (isSystemOwned(spotlight) ? "yes" : "no")
			)
		}
		return failures.isEmpty
	}

	private static let keyCodeDefault = "hotKeyCode"
	private static let modifiersDefault = "hotKeyModifiers"
	private static let keyNameDefault = "hotKeyName"

	private static func loadFromDefaults() -> Combination? {
		let defaults = UserDefaults.standard
		guard
			let keyName = defaults.string(forKey: keyNameDefault),
			defaults.object(forKey: keyCodeDefault) != nil
		else { return nil }
		return Combination(
			keyCode: UInt32(defaults.integer(forKey: keyCodeDefault)),
			carbonModifiers: UInt32(defaults.integer(forKey: modifiersDefault)),
			keyName: keyName
		)
	}

	private static func save(_ combination: Combination) {
		let defaults = UserDefaults.standard
		defaults.set(Int(combination.keyCode), forKey: keyCodeDefault)
		defaults.set(Int(combination.carbonModifiers), forKey: modifiersDefault)
		defaults.set(combination.keyName, forKey: keyNameDefault)
	}
}

/// Action of the one registered hotkey.
///
/// The Carbon handler below is a plain C function pointer and cannot capture anything, so going
/// through a file-global variable is the intended way to do this. It is written only from
/// ``GlobalHotKey/init(action:)`` and read only in the handler, both on the main thread.
private nonisolated(unsafe) var registeredAction: (@MainActor () -> Void)?

private func hotKeyEventHandler(
	_ nextHandler: EventHandlerCallRef?,
	_ event: EventRef?,
	_ userData: UnsafeMutableRawPointer?
) -> OSStatus {
	// Carbon delivers hotkey events on the main event loop.
	MainActor.assumeIsolated { registeredAction?() }
	return noErr
}
