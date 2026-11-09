//
//  FeedSettings.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 3/7/26
//

import Foundation
import RSWeb
import Articles

@MainActor final class FeedSettings {
	private let feedURL: String
	private let database: FeedSettingsDatabase
	weak var feed: Feed?

	// Reassign only before a Feed is created from these settings — Feed copies feedID at init and hashes on it.
	var feedID: String {
		didSet {
			if feedID != oldValue {
				database.setString(feedID, for: feedURL, column: .feedID)
				postSettingDidChange(.feedID)
			}
		}
	}

	var homePageURL: String? {
		didSet {
			if homePageURL != oldValue {
				database.setString(homePageURL, for: feedURL, column: .homePageURL)
				postSettingDidChange(.homePageURL)
			}
		}
	}

	var iconURL: String? {
		didSet {
			if iconURL != oldValue {
				database.setString(iconURL, for: feedURL, column: .iconURL)
				postSettingDidChange(.iconURL)
			}
		}
	}

	var faviconURL: String? {
		didSet {
			if faviconURL != oldValue {
				database.setString(faviconURL, for: feedURL, column: .faviconURL)
				postSettingDidChange(.faviconURL)
			}
		}
	}

	var editedName: String? {
		didSet {
			if editedName != oldValue {
				database.setString(editedName, for: feedURL, column: .editedName)
				postSettingDidChange(.editedName)
			}
		}
	}

	var contentHash: String? {
		didSet {
			if contentHash != oldValue {
				database.setString(contentHash, for: feedURL, column: .contentHash)
				postSettingDidChange(.contentHash)
			}
		}
	}

	var newArticleNotificationsEnabled = false {
		didSet {
			if newArticleNotificationsEnabled != oldValue {
				database.setBool(newArticleNotificationsEnabled, for: feedURL, column: .newArticleNotificationsEnabled)
				postSettingDidChange(.newArticleNotificationsEnabled)
			}
		}
	}

	var readerViewAlwaysEnabled = false {
		didSet {
			if readerViewAlwaysEnabled != oldValue {
				database.setBool(readerViewAlwaysEnabled, for: feedURL, column: .readerViewAlwaysEnabled)
				postSettingDidChange(.readerViewAlwaysEnabled)
			}
		}
	}

	// The two AI switches use backing storage so syncing values written by the
	// language detector or a user override cannot trigger the setters and write
	// the database a second time.
	private var aiRewriteEnabledValue = true
	var aiRewriteEnabled: Bool {
		get {
			aiRewriteEnabledValue
		}
		set {
			guard newValue != aiRewriteEnabledValue else {
				return
			}
			aiRewriteEnabledValue = newValue
			database.setBool(newValue, for: feedURL, column: .aiRewriteEnabled)
			postSettingDidChange(.aiRewriteEnabled)
		}
	}

	private var aiTranslationEnabledValue = true
	var aiTranslationEnabled: Bool {
		get {
			aiTranslationEnabledValue
		}
		set {
			guard newValue != aiTranslationEnabledValue else {
				return
			}
			aiTranslationEnabledValue = newValue
			database.setBool(newValue, for: feedURL, column: .aiTranslationEnabled)
			postSettingDidChange(.aiTranslationEnabled)
		}
	}

	/// True when the user turned an AI switch back on after the automatic
	/// Chinese-feed detection turned it off. Automatic detection leaves the feed
	/// alone from then on.
	private(set) var aiLanguageOverride = false

	var authors: Set<Author>? {
		didSet {
			if authors != oldValue {
				database.setAuthors(authors, for: feedURL)
				postSettingDidChange(.authors)
			}
		}
	}

	var conditionalGetInfo: HTTPConditionalGetInfo? {
		didSet {
			if conditionalGetInfo != oldValue {
				database.setConditionalGetInfo(conditionalGetInfo, for: feedURL)
				postSettingDidChange(.conditionalGetInfo)
				if conditionalGetInfo == nil {
					conditionalGetInfoDate = nil
				} else {
					conditionalGetInfoDate = Date()
				}
			}
		}
	}

	var conditionalGetInfoDate: Date? {
		didSet {
			if conditionalGetInfoDate != oldValue {
				database.setDate(conditionalGetInfoDate, for: feedURL, column: .conditionalGetInfoDate)
				postSettingDidChange(.conditionalGetInfoDate)
			}
		}
	}

	var cacheControlInfo: CacheControlInfo? {
		didSet {
			if cacheControlInfo != oldValue {
				database.setCacheControlInfo(cacheControlInfo, for: feedURL)
				postSettingDidChange(.cacheControlInfo)
			}
		}
	}

	var externalID: String? {
		didSet {
			if externalID != oldValue {
				database.setString(externalID, for: feedURL, column: .externalID)
				postSettingDidChange(.externalID)
			}
		}
	}

	// Folder Name: Sync Service Relationship ID
	var folderRelationship: [String: String]? {
		didSet {
			if folderRelationship != oldValue {
				database.setFolderRelationship(folderRelationship, for: feedURL)
				postSettingDidChange(.folderRelationship)
			}
		}
	}

	/// Last time an attempt was made to read the feed.
	/// (Not necessarily a successful attempt.)
	var lastCheckDate: Date? {
		didSet {
			if lastCheckDate != oldValue {
				database.setDate(lastCheckDate, for: feedURL, column: .lastCheckDate)
				postSettingDidChange(.lastCheckDate)
			}
		}
	}

	/// HTTP status code from the most recent feed download attempt.
	var lastResponseCode: Int? {
		didSet {
			if lastResponseCode != oldValue {
				database.setInt(lastResponseCode, for: feedURL, column: .lastResponseCode)
				postSettingDidChange(.lastResponseCode)
			}
		}
	}

	/// Create from database row (bulk load at startup).
	init(feedURL: String, row: FeedSettingsDatabase.Row, database: FeedSettingsDatabase) {
		self.feedURL = feedURL
		self.database = database
		self.feedID = row.feedID
		self.homePageURL = row.homePageURL
		self.iconURL = row.iconURL
		self.faviconURL = row.faviconURL
		self.editedName = row.editedName
		self.contentHash = row.contentHash
		self.newArticleNotificationsEnabled = row.newArticleNotificationsEnabled
		self.readerViewAlwaysEnabled = row.readerViewAlwaysEnabled
		self.aiRewriteEnabledValue = row.aiRewriteEnabled
		self.aiTranslationEnabledValue = row.aiTranslationEnabled
		self.aiLanguageOverride = row.aiLanguageOverride
		self.authors = row.authors
		self.conditionalGetInfo = row.conditionalGetInfo
		self.conditionalGetInfoDate = row.conditionalGetInfoDate
		self.cacheControlInfo = row.cacheControlInfo
		self.externalID = row.externalID
		self.folderRelationship = row.folderRelationship
		self.lastCheckDate = row.lastCheckDate
		self.lastResponseCode = row.lastResponseCode
	}

	/// Create for a new feed not yet in the database.
	init(feedURL: String, feedID: String, database: FeedSettingsDatabase) {
		self.feedURL = feedURL
		self.database = database
		self.feedID = feedID
		database.ensureFeedExists(feedURL, feedID: feedID)
	}

	/// Applies the automatic Chinese-feed result. The conditional UPDATE is the
	/// only database write, so a user override that lands first wins. Returns
	/// false when the user had already overridden the setting.
	@discardableResult
	func applyAutomaticChineseOff() -> Bool {
		guard database.applyAutomaticChineseOff(for: feedURL) else {
			return false
		}
		syncAIState(FeedSettingsDatabase.AIState(rewriteEnabled: false, translationEnabled: false, languageOverride: false))
		postSettingDidChange(.aiRewriteEnabled)
		postSettingDidChange(.aiTranslationEnabled)
		return true
	}

	/// Called when the user turns an AI switch from off to on. Writes the
	/// override and the switch they turned on through a single UPDATE; the
	/// switch they did not touch keeps its stored value. Turning a switch off
	/// does not come through here, so it never sets the override.
	@discardableResult
	func setAIEnabledByUser(rewriteEnabled: Bool, translationEnabled: Bool) -> Bool {
		let turningOnRewrite = rewriteEnabled && rewriteEnabled != aiRewriteEnabledValue
		let turningOnTranslation = translationEnabled && translationEnabled != aiTranslationEnabledValue
		guard turningOnRewrite || turningOnTranslation else {
			return false
		}
		guard let state = database.setAIEnabledByUser(
			for: feedURL,
			rewriteEnabled: turningOnRewrite ? true : nil,
			translationEnabled: turningOnTranslation ? true : nil
		) else {
			return false
		}
		let oldRewriteEnabled = aiRewriteEnabledValue
		let oldTranslationEnabled = aiTranslationEnabledValue
		syncAIState(state)
		if oldRewriteEnabled != state.rewriteEnabled {
			postSettingDidChange(.aiRewriteEnabled)
		}
		if oldTranslationEnabled != state.translationEnabled {
			postSettingDidChange(.aiTranslationEnabled)
		}
		return true
	}

	private func syncAIState(_ state: FeedSettingsDatabase.AIState) {
		aiRewriteEnabledValue = state.rewriteEnabled
		aiTranslationEnabledValue = state.translationEnabled
		aiLanguageOverride = state.languageOverride
	}

	private func postSettingDidChange(_ key: Feed.SettingKey) {
		guard let feed else {
			// Settings used without a live Feed still report their changes.
			NotificationCenter.default.post(
				name: .feedSettingDidChange,
				object: self,
				userInfo: [Feed.SettingUserInfoKey: key]
			)
			return
		}
		feed.postFeedSettingDidChangeNotification(key)
	}
}
