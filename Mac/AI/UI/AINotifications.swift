//
//  AINotifications.swift
//  NetNewsWire
//

import Foundation

extension Notification.Name {

	/// Posted when another part of the app wants the AI chat input focused.
	static let aiAskRequested = Notification.Name("AIAskRequested")

	/// Posted when a body translation has been saved. `userInfo` carries the article ID.
	static let aiTranslationReady = Notification.Name("AITranslationReady")
}

enum AIUserInfoKey {
	static let articleID = "articleID"
}

/// A plain flipped view, so stack views inside scroll views start at the top.
final class AIFlippedView: NSView {

	override var isFlipped: Bool {
		true
	}
}
