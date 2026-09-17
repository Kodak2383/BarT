import Carbon.HIToolbox

/// A system-wide registered key combination.
///
/// Deliberately built on the Carbon hotkey API rather than `NSEvent.addGlobalMonitorForEvents`:
/// a global keyboard monitor would see *every* keystroke the user makes — passwords included —
/// and would still pass the combination on to the frontmost app as well. `RegisterEventHotKey`
/// registers this one combination and swallows it.
///
/// ponytail: hard-wired instead of configurable. A shortcut recorder would be more UI than all
/// the other settings put together; on a collision ``isRegistered`` reports `false` and the
/// settings say so. Make it configurable once somebody trips over the assignment.
///
/// Lives as long as the app does — hence no `deinit`, which would only ever run at quit.
@MainActor
final class GlobalHotKey {
	/// ⌃⌥⌘B. Three modifiers, so it stays out of everyone's way.
	static let displayName = "⌃⌥⌘B"

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

		// The signature is arbitrary, it only has to be unique within the app: "BTHK".
		let id = EventHotKeyID(signature: 0x4254_484B, id: 1)
		guard RegisterEventHotKey(
			UInt32(kVK_ANSI_B),
			UInt32(controlKey | optionKey | cmdKey),
			id,
			GetApplicationEventTarget(),
			0,
			&hotKeyRef
		) == noErr else { return }

		isRegistered = true
	}
}

/// Action of the one registered hotkey.
///
/// The Carbon handler below is a plain C function pointer and cannot capture anything — going
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
