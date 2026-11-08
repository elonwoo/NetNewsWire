//
//  AIJobNotifications.swift
//  NetNewsWire
//

import Foundation

extension Notification.Name {
	static let aiTranslationReady = Notification.Name("AITranslationReady")
	static let aiRewriteReady = Notification.Name("AIRewriteReady")
	static let aiJobFailed = Notification.Name("AIJobFailed")
}

enum AIJobNotificationKey {
	static let articleID = "articleID"
	static let error = "error"
}
