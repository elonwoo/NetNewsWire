//
//  AIJobNotifications.swift
//  NetNewsWire
//

import Foundation

extension Notification.Name {
	static let aiRewriteReady = Notification.Name("AIRewriteReady")
	static let aiRewriteStored = Notification.Name("AIRewriteStored")
	static let aiRewriteRemoved = Notification.Name("AIRewriteRemoved")
	static let aiJobFailed = Notification.Name("AIJobFailed")
	static let aiTimelineArticlesDidChange = Notification.Name("AITimelineArticlesDidChange")
}
