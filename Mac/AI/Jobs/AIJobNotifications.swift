//
//  AIJobNotifications.swift
//  NetNewsWire
//

import Foundation

extension Notification.Name {
	static let aiRewriteReady = Notification.Name("AIRewriteReady")
	static let aiRewriteStored = Notification.Name("AIRewriteStored")
	static let aiJobFailed = Notification.Name("AIJobFailed")
}
