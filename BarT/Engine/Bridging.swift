import AppKit
import CoreGraphics
import Foundation
import OSLog

// Private CoreGraphics-Services-API (CGS).
//
// Herkunft: Signaturen 1:1 verifiziert gegen das Open-Source-Projekt "Ice" (MIT),
// Datei Ice/Bridging/Shims/Private.swift, Commit 11edd39115f3f43a83ae114b5348df6a0e1741cf
// (https://github.com/jordanbaird/Ice). Nicht erraten — falsche Signaturen führen hier
// zu stillen Speicherfehlern, nicht zu Compilerfehlern.
//
// @_silgen_name bindet direkt gegen das C-Symbol in CoreGraphics.framework. Es gibt
// keinen Header und keine Deprecation-Warnung: entfernt Apple ein Symbol, schlägt der
// dyld-Bind beim App-Start fehl (Crash), nicht der Build. Prüfe diese Datei daher bei
// jedem macOS-Major-Update gegen eine laufende Testinstallation.

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
func CGSGetWindowCount(
	_ cid: CGSConnectionID,
	_ targetCID: CGSConnectionID,
	_ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowCount")
func CGSGetOnScreenWindowCount(
	_ cid: CGSConnectionID,
	_ targetCID: CGSConnectionID,
	_ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowList")
func CGSGetOnScreenWindowList(
	_ cid: CGSConnectionID,
	_ targetCID: CGSConnectionID,
	_ count: Int32,
	_ list: UnsafeMutablePointer<CGWindowID>,
	_ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
func CGSGetProcessMenuBarWindowList(
	_ cid: CGSConnectionID,
	_ targetCID: CGSConnectionID,
	_ count: Int32,
	_ list: UnsafeMutablePointer<CGWindowID>,
	_ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
func CGSGetScreenRectForWindow(
	_ cid: CGSConnectionID,
	_ wid: CGWindowID,
	_ outRect: inout CGRect
) -> CGError

// Process-Manager-API, in Swift als "unavailable" importiert (deprecated seit 10.9), das
// Symbol existiert aber weiterhin. Eigener Swift-Name, damit es nicht mit dem
// unbenutzbaren Import kollidiert. Shim-Idee aus Ice, Ice/Bridging/Shims/Deprecated.swift.
@_silgen_name("GetProcessForPID")
func shimGetProcessForPID(
	_ pid: pid_t,
	_ psn: inout ProcessSerialNumber
) -> OSStatus

@_silgen_name("CGSEventIsAppUnresponsive")
func CGSEventIsAppUnresponsive(
	_ cid: CGSConnectionID,
	_ psn: inout ProcessSerialNumber
) -> Bool

// MARK: - Swift-Fassade

private let log = Logger(subsystem: "de.andreduhme.BarT", category: "CGSBridge")

enum CGSBridge {
	/// Fenster-IDs aller Menüleisten-Items *aller* laufenden Prozesse.
	///
	/// - Parameter onScreenOnly: Nur Items, die aktuell sichtbar gerendert werden.
	///   Genau dieses Flag unterscheidet ein "verstecktes" (nach links aus der Leiste
	///   geschobenes) Item von einem sichtbaren.
	static func menuBarWindowIDs(onScreenOnly: Bool) -> [CGWindowID] {
		let list = menuBarWindowList()
		guard onScreenOnly else { return list }
		let onScreen = Set(onScreenWindowList())
		return list.filter(onScreen.contains)
	}

	/// Fensterrahmen in globalen CG-Koordinaten (Ursprung oben links) — dieselbe
	/// Koordinatenbasis, die `CGEvent` für `mouseCursorPosition` erwartet. Kein Flip nötig.
	/// `NSScreen.frame` ist dagegen unten-links-basiert; nicht vermischen.
	static func frame(for windowID: CGWindowID) -> CGRect? {
		var rect = CGRect.zero
		let result = CGSGetScreenRectForWindow(CGSMainConnectionID(), windowID, &rect)
		guard result == .success else {
			log.error("CGSGetScreenRectForWindow(\(windowID)) failed: \(result.rawValue)")
			return nil
		}
		return rect
	}

	/// Ein nicht reagierender Owner-Prozess nimmt den synthetischen Cmd-Drag nicht an
	/// und lässt den Drag-Zustand hängen. Vor jedem Drag prüfen.
	static func isUnresponsive(pid: pid_t) -> Bool {
		var psn = ProcessSerialNumber()
		guard shimGetProcessForPID(pid, &psn) == noErr else { return false }
		return CGSEventIsAppUnresponsive(CGSMainConnectionID(), &psn)
	}

	// MARK: Intern

	private static func windowCount() -> Int {
		var count: Int32 = 0
		let result = CGSGetWindowCount(CGSMainConnectionID(), 0, &count)
		guard result == .success else {
			log.error("CGSGetWindowCount failed: \(result.rawValue)")
			return 0
		}
		return Int(count)
	}

	private static func onScreenWindowCount() -> Int {
		var count: Int32 = 0
		let result = CGSGetOnScreenWindowCount(CGSMainConnectionID(), 0, &count)
		guard result == .success else {
			log.error("CGSGetOnScreenWindowCount failed: \(result.rawValue)")
			return 0
		}
		return Int(count)
	}

	private static func menuBarWindowList() -> [CGWindowID] {
		// Puffer wird mit der *gesamten* Fensteranzahl dimensioniert: zwischen Zählung
		// und Abruf kann ein Prozess Items hinzufügen, und CGS schreibt ungeprüft.
		let capacity = windowCount()
		guard capacity > 0 else { return [] }
		var list = [CGWindowID](repeating: 0, count: capacity)
		var realCount: Int32 = 0
		let result = CGSGetProcessMenuBarWindowList(
			CGSMainConnectionID(), 0, Int32(capacity), &list, &realCount
		)
		guard result == .success else {
			log.error("CGSGetProcessMenuBarWindowList failed: \(result.rawValue)")
			return []
		}
		return Array(list[..<Int(realCount)])
	}

	private static func onScreenWindowList() -> [CGWindowID] {
		let capacity = onScreenWindowCount()
		guard capacity > 0 else { return [] }
		var list = [CGWindowID](repeating: 0, count: capacity)
		var realCount: Int32 = 0
		let result = CGSGetOnScreenWindowList(
			CGSMainConnectionID(), 0, Int32(capacity), &list, &realCount
		)
		guard result == .success else {
			log.error("CGSGetOnScreenWindowList failed: \(result.rawValue)")
			return []
		}
		return Array(list[..<Int(realCount)])
	}
}
