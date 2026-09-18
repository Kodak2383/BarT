import AppKit
import CoreGraphics
import Foundation
import OSLog

// Private CoreGraphics Services API (CGS).
//
// Provenance. Five of the six signatures are the public CGSInternal header archive verbatim
// (https://github.com/NUIKit/CGSInternal, CGSConnection.h and CGSWindow.h), down to the
// parameter names. CGSGetProcessMenuBarWindowList is in no public header: its signature was
// taken from Ice (GPL-3.0, Ice/Bridging/Shims/Private.swift, commit
// 11edd39115f3f43a83ae114b5348df6a0e1741cf) and mirrors its sibling CGSGetOnScreenWindowList
// parameter for parameter. The symbol itself is Apple's: CoreGraphics re-exports it from
// SkyLight, checked with `dyld_info -exports`.
//
// None of this is guessed, and that is the point: a wrong signature here causes silent memory
// corruption, not a compiler error.
//
// @_silgen_name binds straight against the C symbol in CoreGraphics.framework. There is no
// header and no deprecation warning: if Apple removes a symbol, the dyld bind fails at app
// launch (a crash), not at build time. So check this file against a running test install on
// every major macOS update.

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

// MARK: - Swift facade

private let log = Logger(subsystem: "de.andreduhme.BarT", category: "CGSBridge")

enum CGSBridge {
	/// Window IDs of the menu bar items of *all* running processes.
	///
	/// - Parameter onScreenOnly: only items that are currently rendered visibly. This flag is
	///   exactly what distinguishes a "hidden" item (pushed off to the left out of the bar)
	///   from a visible one.
	static func menuBarWindowIDs(onScreenOnly: Bool) -> [CGWindowID] {
		let list = menuBarWindowList()
		guard onScreenOnly else { return list }
		let onScreen = Set(onScreenWindowList())
		return list.filter(onScreen.contains)
	}

	/// Window frame in global CG coordinates (origin top left), the same coordinate basis
	/// `CGEvent` expects for `mouseCursorPosition`. No flip needed. `NSScreen.frame`, by
	/// contrast, is bottom-left based; do not mix the two.
	static func frame(for windowID: CGWindowID) -> CGRect? {
		var rect = CGRect.zero
		let result = CGSGetScreenRectForWindow(CGSMainConnectionID(), windowID, &rect)
		guard result == .success else {
			log.error("CGSGetScreenRectForWindow(\(windowID)) failed: \(result.rawValue)")
			return nil
		}
		return rect
	}

	// MARK: Internal

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
		// The buffer is sized to the *total* window count: between counting and fetching a
		// process can add items, and CGS writes without checking.
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
