import CoreGraphics
import OSLog

/// Minimaler CGEvent-Tap — nur so weit ausgebaut, wie ``DragHideEngine`` ihn für die
/// Zustellung ihrer Drag-Events braucht (siehe dort ``DragHideEngine/scromble(_:pid:)``).
///
/// Tap-Konstruktion übernommen aus Ice (MIT), Ice/Events/EventTap.swift.
///
/// Es gibt bewusst keinen `deinit`: der wäre in Swift 6 nicht MainActor-isoliert und
/// käme an die gespeicherten Eigenschaften nicht heran. Jeder Tap muss deshalb
/// explizit über ``invalidate()`` abgebaut werden.
@MainActor
final class EventTap {
	enum Location {
		case sessionEventTap
		case pid(pid_t)
	}

	/// Rückgabe `nil` verwirft das Event — wirkt nur bei `options == .defaultTap`.
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
				eventsOfInterest: mask, callback: barToolEventTapCallback, userInfo: userInfo
			)
		case .sessionEventTap:
			CGEvent.tapCreate(
				tap: .cgSessionEventTap, place: .tailAppendEventTap, options: options,
				eventsOfInterest: mask, callback: barToolEventTapCallback, userInfo: userInfo
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
		// Deaktiviert das System den Tap (Timeout/Nutzereingabe), ist er sonst still tot.
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
			enable()
			return event
		}
		return handler(self, type, event)
	}
}

/// C-Callback des Taps. Die Run-Loop-Source hängt am Main-Run-Loop, der Callback läuft
/// also auf dem Main-Thread — `assumeIsolated` ist hier korrekt und nicht geraten.
private func barToolEventTapCallback(
	proxy: CGEventTapProxy,
	type: CGEventType,
	event: CGEvent,
	userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	guard let userInfo else { return Unmanaged.passUnretained(event) }
	// Zeiger als Ganzzahl durch den `assumeIsolated`-Block reichen: weder `CGEvent` noch
	// die Zeigertypen selbst sind `Sendable`, die Isolationsprüfung lässt sie sonst nicht
	// passieren. Die Objekte leben währenddessen garantiert weiter — CoreGraphics hält das
	// Event über den Callback hinweg, den Tap hält ``DragHideEngine``.
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
