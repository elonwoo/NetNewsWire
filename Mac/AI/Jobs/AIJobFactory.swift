//
//  AIJobFactory.swift
//  NetNewsWire
//

import AI
import Foundation

enum AIJobFactory {

	static func job(articleID: String, kind: AIJobKind, now: Date = Date()) -> AIJob {
		AIJob(
			id: UUID().uuidString,
			articleID: articleID,
			kind: kind,
			priority: priority(for: kind),
			availableAt: now,
			createdAt: now
		)
	}

	/// User-visible work outranks background work. Body translation is started
	/// from the reading pane, title translation fills the timeline, and rewrites
	/// run in the background.
	static func priority(for kind: AIJobKind) -> Int {
		switch kind {
		case .bodyTranslation:
			return 100
		case .titleTranslation:
			return 50
		case .rewrite:
			return 10
		}
	}
}
