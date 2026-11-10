//
//  MainWindowKeyboardHandler.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 12/19/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import AppKit
import RSCore

@MainActor final class MainWindowKeyboardHandler: KeyboardDelegate {
	static let shared = MainWindowKeyboardHandler()
	private static let escapeKeyCode: UInt16 = 53
	let globalShortcuts: Set<KeyboardShortcut>

	init() {
		let f = Bundle.main.path(forResource: "GlobalKeyboardShortcuts", ofType: "plist")!
		let rawShortcuts = NSArray(contentsOfFile: f)! as! [[String: Any]]

		self.globalShortcuts = Set(rawShortcuts.compactMap { KeyboardShortcut(dictionary: $0) })
	}

	func keydown(_ event: NSEvent, in view: NSView) -> Bool {
		// Escape is not representable in the shortcut plists, so handle it here.
		// The AI bar closes first; immersive reading exits on the next press.
		if event.keyCode == Self.escapeKeyCode {
			if let mainWindowController = view.window?.windowController as? MainWindowController,
			   mainWindowController.closeAIPaneIfVisible() {
				return true
			}
			if ImmersiveReadingMode.shared.exit(for: view.window) {
				return true
			}
			if let mainWindowController = view.window?.windowController as? MainWindowController,
			   mainWindowController.closeSelectedArticleOnEscape(from: view) {
				return true
			}
		}

		let key = KeyboardKey(with: event)
		guard let matchingShortcut = KeyboardShortcut.findMatchingShortcut(in: globalShortcuts, key: key) else {
			return false
		}

		matchingShortcut.perform(with: view)
		return true
	}
}
