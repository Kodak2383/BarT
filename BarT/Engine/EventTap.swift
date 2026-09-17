import CoreGraphics
import OSLog

/// Minimal CGEvent tap — built out only as far as ``DragHideEngine`` needs it to deliver its
/// drag events (see ``DragHideEngine/scromble(_:pid:)`` there).
///
/// Tap construction taken from Ice (MIT), Ice/Events/EventTap.swift.
///
/// There is deliberately no `deinit`: under Swift 6 it would not be MainActor-isolated and
/// could not reach the stored properties. Every tap therefore has to be torn down explicitly
/// via ``invalidate()``.
@MainActor
final class EventTap {
	enum Location {
		case sessionEventTap
		case pid(pid_t)
	}

	/// Returning `nil` discards the event — which only takes effect for `options == .defaultTap`.
	typealias Handler = @MainActor (EventTap, CGEventType, CGEvent) -> CGEvent?

	private let handler: Handler
	private var machPort: CFMachPort?
	private var source: CFRunLoopSource?

	init?(options: CGEventTapOptions, location: Location, types: [CGEventType], handler: @escaping Handler) {
		self.handler = handler

		let mask = types.reduce(into: CGEventMask(0)) { $0 |= 1 << $1.rawValue }
		let userInfo = Unmanaged.passUnretained(self).toOpaque()
		let port: CFMachPort? = switch location {
		case .pid(let pid):
			CGEvent.tapCreateForPid(
				pid: pid, place: .tailAppendEventTap, options: options,
				eventsOfInterest: mask, callback: eventTapCallback, userInfo: userInfo
			)
		case .sessionEventTap:
			CGEvent.tapCreate(
				tap: .cgSessionEventTap, place: .tailAppendEventTap, options: options,
				eventsOfInterest: mask, callback: eventTapCallback, userInfo: userInfo
			)
		}

		guard let port, let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
		self.machPort = port
		self.source = source
	}

	func enable() {
		guard let machPort, let source else { return }
		CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
		CGEvent.tapEnable(tap: machPort, enable: true)
	}

	func disable() {
		guard let machPort else { return }
		CGEvent.tapEnable(tap: machPort, enable: false)
	}

	var isEnabled: Bool {
		guard let machPort else { return false }
		return CGEvent.tapIsEnabled(tap: machPort)
	}

	func invalidate() {
		guard let machPort, let source else { return }
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
		CGEvent.tapEnable(tap: machPort, enable: false)
		CFMachPortInvalidate(machPort)
		self.machPort = nil
		self.source = nil
	}

	fileprivate func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
		// When the system disables the tap (timeout or user input), it would silently stay dead.
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
			enable()
			return event
		}
		return handler(self, type, event)
	}
}

/// The tap's C callback. The run loop source is attached to the main run loop, so the callback
/// runs on the main thread — `assumeIsolated` is correct here, not a guess.
private func eventTapCallback(
	proxy: CGEventTapProxy,
	type: CGEventType,
	event: CGEvent,
	userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	guard let userInfo else { return Unmanaged.passUnretained(event) }
	// Pass the pointers through the `assumeIsolated` block as integers: neither `CGEvent` nor
	// the pointer types themselves are `Sendable`, so the isolation check would not let them
	// through otherwise. The objects are guaranteed to stay alive meanwhile — CoreGraphics
	// holds the event across the callback, and ``DragHideEngine`` holds the tap.
	let tapBits = UInt(bitPattern: userInfo)
	let eventBits = UInt(bitPattern: Unmanaged.passUnretained(event).toOpaque())
	var resultBits: UInt = 0

	MainActor.assumeIsolated {
		guard
			let tapPointer = UnsafeRawPointer(bitPattern: tapBits),
			let eventPointer = UnsafeRawPointer(bitPattern: eventBits)
		else { return }
		let tap = Unmanaged<EventTap>.fromOpaque(tapPointer).takeUnretainedValue()
		let event = Unmanaged<CGEvent>.fromOpaque(eventPointer).takeUnretainedValue()
		guard let result = tap.handle(type: type, event: event) else { return }
		resultBits = UInt(bitPattern: Unmanaged.passUnretained(result).toOpaque())
	}

	guard let resultPointer = UnsafeRawPointer(bitPattern: resultBits) else { return nil }
	return Unmanaged<CGEvent>.fromOpaque(resultPointer)
}
