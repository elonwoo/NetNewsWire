//
//  TimelineDotPolicy.swift
//  NetNewsWire
//

import Foundation

/// The unread indicator's color for a timeline row.
enum TimelineDot: Equatable {
	case none
	case blue
	case yellow
	case green
}

/// Chooses the dot color from the row state.
///
/// Read and starred rows show no dot. Otherwise a rewrite outranks a
/// translation, which outranks plain unread. A completed rewrite or translation
/// only counts when its per-feed switch is still on.
enum TimelineDotPolicy {

	static func dot(isUnread: Bool, isStarred: Bool, rewriteEnabled: Bool, hasRewrite: Bool, translationEnabled: Bool, hasTranslation: Bool) -> TimelineDot {
		guard isUnread, !isStarred else {
			return .none
		}
		if rewriteEnabled && hasRewrite {
			return .green
		}
		if translationEnabled && hasTranslation {
			return .yellow
		}
		return .blue
	}
}
