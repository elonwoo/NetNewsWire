//
//  AITitleBatchPolicy.swift
//  NetNewsWire
//

import AI
import Foundation

/// Picks the buffered articles that join the currently claimed title job so the
/// engine can translate several titles in one request. Articles whose feed has
/// title translation turned off are left out.
enum AITitleBatchPolicy {

	/// The claimed article always leads the batch, unless its own feed disabled
	/// translation, in which case the batch is empty and the job has nothing to
	/// do. Buffered articles fill the rest of the batch up to `limit`.
	static func batch(article: AIArticle, pending: [String: AIArticle], translationDisabledFeedIDs: Set<String>, limit: Int) -> [AIArticle] {
		guard limit > 0, allowsTranslation(feedID: article.feedID, disabledFeedIDs: translationDisabledFeedIDs) else {
			return []
		}
		var batch = [article]
		for (articleID, pendingArticle) in pending where articleID != article.id && batch.count < limit {
			guard allowsTranslation(feedID: pendingArticle.feedID, disabledFeedIDs: translationDisabledFeedIDs) else {
				continue
			}
			batch.append(pendingArticle)
		}
		return batch
	}

	/// A feed that turned translation off must not be translated. An article
	/// without a feed ID cannot be tied to a disabled feed, so it is allowed.
	static func allowsTranslation(feedID: String?, disabledFeedIDs: Set<String>) -> Bool {
		guard let feedID else {
			return true
		}
		return !disabledFeedIDs.contains(feedID)
	}
}
