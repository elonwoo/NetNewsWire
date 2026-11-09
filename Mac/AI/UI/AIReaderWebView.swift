//
//  AIReaderWebView.swift
//  NetNewsWire
//

import AppKit
import WebKit

/// The rewrite and translation pages are plain web views, so they do not inherit the
/// article view's keyboard routing. Without it the reading shortcuts, Escape included,
/// stop working while one of those tabs has focus.
final class AIReaderWebView: WKWebView {

	override func keyDown(with event: NSEvent) {
		if MainWindowKeyboardHandler.shared.keydown(event, in: self) {
			return
		}
		super.keyDown(with: event)
	}
}

/// The pane's root view takes focus when the web view is hidden, such as on the
/// empty state, so the reading shortcuts keep working there too.
final class AIReaderContainerView: NSView {

	override var acceptsFirstResponder: Bool {
		return true
	}

	override func keyDown(with event: NSEvent) {
		if MainWindowKeyboardHandler.shared.keydown(event, in: self) {
			return
		}
		super.keyDown(with: event)
	}
}
