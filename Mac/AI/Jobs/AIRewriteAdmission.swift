//
//  AIRewriteAdmission.swift
//  NetNewsWire
//

import Foundation

/// Decides whether a feed may run rewrites or translations, for both the pane
/// tabs and the automatic jobs.
enum AIRewriteAdmission {

	/// A feed with rewrite turned off never gets a rewrite. An article without a
	/// feed ID cannot be tied to a disabled feed, so it is allowed.
	///
	/// The lookup is conservative across accounts: a feed ID is blocked when
	/// any account's feed with that ID has the switch off.
	static func allowsRewrite(feedID: String?, rewriteDisabledFeedIDs: Set<String>) -> Bool {
		allows(feedID: feedID, disabledFeedIDs: rewriteDisabledFeedIDs)
	}

	/// A feed with translation turned off never gets a title translation. An
	/// article without a feed ID cannot be tied to a disabled feed, so it is
	/// allowed.
	static func allowsTranslation(feedID: String?, translationDisabledFeedIDs: Set<String>) -> Bool {
		allows(feedID: feedID, disabledFeedIDs: translationDisabledFeedIDs)
	}

	private static func allows(feedID: String?, disabledFeedIDs: Set<String>) -> Bool {
		guard let feedID else {
			return true
		}
		return !disabledFeedIDs.contains(feedID)
	}
}
