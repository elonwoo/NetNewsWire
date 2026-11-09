//
//  LocalAccountRefresher.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/6/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import ErrorLog
import RSCore
import RSParser
import RSWeb
import Articles
import ArticlesDatabase
import ActivityLog
import os

@MainActor protocol LocalAccountRefresherDelegate {
	func localAccountRefresher(_ refresher: LocalAccountRefresher, articleChanges: ArticleChanges)
}

struct RefresherStatsSnapshot: Equatable {

	let feedsErrored: Int
	let newArticlesCount: Int
	let updatedArticlesCount: Int
	let outstandingParseTasks: Int
	let pendingRSSHubRetries: Int
}

@MainActor final class LocalAccountRefresher: ProgressInfoReporter {
	var delegate: LocalAccountRefresherDelegate?

	var progressInfo = ProgressInfo() {
		didSet {
			if progressInfo != oldValue {
				postProgressInfoDidChangeNotification()
			}
		}
	}

	/// Settable by the caller (LocalAccountDelegate / CloudKitAccountDelegate) so
	/// per-refresh activities can be scoped to the right account.
	var accountID: String?

	/// When false, refreshFeeds does not create its own `.refreshAll` activity.
	var publishesRefreshActivity = true

	/// Human-readable stats summary for the most recent (or in-progress) refresh.
	var refreshStatsMessage: String {
		var parts = [String]()
		parts.append("\(feedsTotal) \(feedsTotal == 1 ? "feed" : "feeds")")
		if feedsSkipped > 0 {
			parts.append("\(feedsSkipped) skipped")
		}
		if feedsErrored > 0 {
			parts.append("\(feedsErrored) \(feedsErrored == 1 ? "error" : "errors")")
		}
		parts.append("\(newArticlesCount) new \(newArticlesCount == 1 ? "article" : "articles")")
		parts.append("\(updatedArticlesCount) updated \(updatedArticlesCount == 1 ? "article" : "articles")")
		return parts.joined(separator: ", ")
	}

	private var refreshActivity: (generation: Int, id: Int)?
	private var refreshGeneration = 0
	private var pendingRSSHubRetries = 0
	private var retryingFeedIDs = Set<String>()
	private var feedsTotal = 0
	private var feedsSkipped = 0
	private var feedsErrored = 0
	private var newArticlesCount = 0
	private var updatedArticlesCount = 0
	private var outstandingParseTasks = 0
	private var downloadSessionIsComplete = false

	private var completion: (() -> Void)?
	private var isSuspended = false

	private let rssHubRetrier: RSSHubFallbackRetrier

	init(rssHubRetrier: RSSHubFallbackRetrier = RSSHubFallbackRetrier()) {
		self.rssHubRetrier = rssHubRetrier
	}

	var refreshStatsSnapshot: RefresherStatsSnapshot {
		RefresherStatsSnapshot(feedsErrored: feedsErrored,
							   newArticlesCount: newArticlesCount,
							   updatedArticlesCount: updatedArticlesCount,
							   outstandingParseTasks: outstandingParseTasks,
							   pendingRSSHubRetries: pendingRSSHubRetries)
	}

	var currentRefreshGeneration: Int {
		refreshGeneration
	}

	private lazy var downloadSession: DownloadSession = {
		let session = DownloadSession(delegate: self)
		NotificationCenter.default.addObserver(self, selector: #selector(progressInfoDidChange(_:)), name: .progressInfoDidChange, object: session)
		return session
	}()

	private var urlToFeedDictionary = [String: Feed]()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "LocalAccountRefresher")

	@MainActor public func refreshFeeds(_ feeds: Set<Feed>) async {
		await withCheckedContinuation { continuation in
			Task { @MainActor in
				refreshFeeds(feeds) {
					continuation.resume()
				}
			}
		}
	}

	@MainActor private func refreshFeeds(_ feeds: Set<Feed>, completion: (() -> Void)? = nil) {
		// This refresh replaces any in-flight one, so resume its caller rather than
		// stranding it, and settle the old generation before starting a new one.
		if let previousCompletion = self.completion {
			previousCompletion()
			self.completion = nil
		}
		completeRefreshActivity(message: "Interrupted by a new refresh")
		if let accountID {
			completeRemainingActivities(accountID: accountID)
		}

		refreshGeneration += 1
		let generation = refreshGeneration
		pendingRSSHubRetries = 0
		retryingFeedIDs.removeAll()

		let specialCaseCutoffDate = Date().bySubtracting(hours: 25)
		let redditURLToRefresh = Self.redditURLToRefresh(in: feeds)

		var filteredFeeds = Set<Feed>()
		var skippedFeeds = [(Feed, String)]() // feed and skip reason

		for feed in feeds {
			let (shouldSkip, reason) = Self.feedShouldBeSkipped(feed, specialCaseCutoffDate, redditURLToRefresh)
			if shouldSkip, let reason {
				skippedFeeds.append((feed, reason))
			} else {
				filteredFeeds.insert(feed)
			}
		}

		feedsTotal = feeds.count
		feedsSkipped = skippedFeeds.count
		feedsErrored = 0
		newArticlesCount = 0
		updatedArticlesCount = 0
		outstandingParseTasks = 0
		downloadSessionIsComplete = false

		// Create a pending activity for each feed that will be fetched,
		// to be completed later by the DownloadSessionDelegate callbacks.
		// Log skipped feeds as already completed with their reason.
		if let owner = activityOwner {
			let activityLog = ActivityLog.shared
			if publishesRefreshActivity {
				let activityID = activityLog.createActivity(owner: owner, kind: .refreshAll)
				activityLog.didStart(id: activityID)
				refreshActivity = (generation, activityID)
			}
			for feed in filteredFeeds {
				activityLog.createActivity(owner: owner, kind: .refreshFeedContent(feedURL: feed.url), detail: feed.nameForDisplay)
			}
			for (feed, reason) in skippedFeeds {
				activityLog.logCompletedActivity(owner: owner, kind: .refreshFeedContent(feedURL: feed.url), detail: feed.nameForDisplay, message: reason)
			}
		}

		self.completion = completion

		guard !filteredFeeds.isEmpty else {
			// All feeds were skipped. Finish through the same finalizer.
			downloadSessionIsComplete = true
			finalizeRefreshIfReady()
			return
		}

		// Key on the request URL: `URL(string:)` doesn’t always round-trip feed.url.
		urlToFeedDictionary.removeAll()
		var urls = Set<URL>()
		for feed in filteredFeeds {
			guard let url = Self.url(for: feed) else {
				continue
			}
			urlToFeedDictionary[url.absoluteString] = feed
			urls.insert(url)
		}

		downloadSession.download(urls)
	}

	private var activityOwner: ActivityOwner? {
		guard let accountID else {
			return nil
		}
		let displayName = AccountManager.shared.existingAccount(accountID: accountID)?.nameForDisplay ?? accountID
		return .account(accountID: accountID, displayName: displayName)
	}

	@MainActor public func suspend() {
		isSuspended = true
		// Invalidate in-flight retry and parse tasks, then settle this generation
		// so its completion cannot hang.
		refreshGeneration += 1
		downloadSession.cancelAll()

		completeRefreshActivity(message: "Interrupted by suspend")
		pendingRSSHubRetries = 0
		retryingFeedIDs.removeAll()
		outstandingParseTasks = 0
		downloadSessionIsComplete = true
		finalizeRefreshIfReady()
	}

	@MainActor public func resume() {
		downloadSession.recreateURLSession()
		isSuspended = false
	}

	// MARK: - Notifications

	@objc func progressInfoDidChange(_ notification: Notification) {
		progressInfo = downloadSession.progressInfo
	}
}

// MARK: - DownloadSessionDelegate

@MainActor extension LocalAccountRefresher: DownloadSessionDelegate {

	func downloadSession(_ downloadSession: DownloadSession, conditionalGetInfoFor url: URL) -> HTTPConditionalGetInfo? {

		guard let feed = urlToFeedDictionary[url.absoluteString] else {
			assertionFailure("LocalAccountRefresher: expected feed for \(url)")
			Self.logger.debug("LocalAccountRefresher: expected feed for \(url)")
			return nil
		}
		guard let conditionalGetInfo = feed.conditionalGetInfo else {
			Self.logger.debug("LocalAccountRefresher: no conditional GET info for \(url)")
			return nil
		}

		// Conditional GET info is dropped every 8 days, because some servers just always
		// respond with a 304 when *any* conditional GET info is sent, which means
		// those feeds don’t get updated. By dropping conditional GET info periodically,
		// we make sure those feeds get updated.
		if let conditionalGetInfoDate = feed.conditionalGetInfoDate {
			let eightDaysAgo = Date().bySubtracting(days: 8)
			if conditionalGetInfoDate < eightDaysAgo {
				if !SpecialCase.urlStringContainSpecialCase( url.absoluteString, [SpecialCase.openRSSOrgHostName, SpecialCase.rachelByTheBayHostName]) {
					Self.logger.info("LocalAccountRefresher: dropping conditional GET info for \(url) — more than 8 days old")
					feed.conditionalGetInfo = nil
					return nil
				}
			}
		}

		return conditionalGetInfo
	}

	func downloadSession(_ downloadSession: DownloadSession, didReceiveResponse url: URL) {
		guard let feed = urlToFeedDictionary[url.absoluteString], let owner = activityOwner else {
			return
		}
		ActivityLog.shared.didStart(owner, kind: .refreshFeedContent(feedURL: feed.url))
	}

	func downloadSession(_ downloadSession: DownloadSession, didFollowRedirectFor url: URL, from fromURL: URL, to toURL: URL, statusCode: Int) {
		guard let owner = activityOwner else {
			return
		}
		let detail = urlToFeedDictionary[url.absoluteString]?.nameForDisplay
		ActivityLog.shared.logCompletedActivity(owner: owner, kind: .followFeedRedirect, detail: detail, message: "\(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode)): \(fromURL.absoluteString) → \(toURL.absoluteString)")
	}

	func downloadSession(_ downloadSession: DownloadSession, didSkip url: URL, reason: String) {
		guard let owner = activityOwner else {
			return
		}
		let kind = ActivityKind.refreshFeedContent(feedURL: url.absoluteString)
		let feed = urlToFeedDictionary[url.absoluteString]

		// DownloadSession only skips because of its in-memory 4xx cache (or a
		// previous 429). That cache is populated by `httpError`, which also wrote
		// `lastResponseCode`, so this 4xx check depends on httpError running first.
		if let feed,
		   !isSuspended,
		   let statusCode = feed.lastResponseCode,
		   (400..<500).contains(statusCode),
		   statusCode != 429,
		   attemptRSSHubRetry(feed: feed, url: url, generation: refreshGeneration, triggerError: nil) {
			ActivityLog.shared.startIfNeeded(owner, kind: kind)
			return
		}

		ActivityLog.shared.startIfNeeded(owner, kind: kind)
		ActivityLog.shared.didComplete(owner, kind: kind, message: reason, durationIsSignificant: false)
	}

	func downloadSession(_ downloadSession: DownloadSession, downloadDidComplete url: URL, response: URLResponse?, data: Data, error: NSError?) {

		guard let feed = urlToFeedDictionary[url.absoluteString] else {
			return
		}
		handleDownloadCompletion(feed: feed, url: url, response: response, data: data, error: error, generation: refreshGeneration)
	}

	func handleDownloadCompletion(feed: Feed, url: URL, response: URLResponse?, data: Data, error: NSError?, generation: Int) {
		guard generation == refreshGeneration else {
			return
		}

		// Skip updating lastCheckDate on connectivity errors, so the feed
		// isn't skipped for timing reasons on the next refresh.
		if !errorIsConnectivityRelated(error) {
			feed.lastCheckDate = Date()
		}

		let activityKind = ActivityKind.refreshFeedContent(feedURL: feed.url)

		if let error {
			if attemptRSSHubRetry(feed: feed, url: url, generation: generation, triggerError: error) {
				return
			}
			reportFeedRefreshError(feed: feed, error: error, activityKind: activityKind)
			return
		}
		guard let httpResponse = response as? HTTPURLResponse else {
			let error = NSError(domain: "LocalAccountRefresher", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unexpected response (not HTTP)"])
			if attemptRSSHubRetry(feed: feed, url: url, generation: generation, triggerError: error) {
				return
			}
			reportFeedRefreshError(feed: feed, error: error, activityKind: activityKind)
			return
		}

		feed.lastResponseCode = httpResponse.statusCode

		let statusIsOK = httpResponse.statusIsOK
		let statusIsOKOrNotModified = statusIsOK || httpResponse.statusCode == HTTPResponseCode.notModified
		guard statusIsOKOrNotModified else {
			let statusCode = httpResponse.statusCode
			let error = NSError(domain: "LocalAccountRefresher", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode)"])
			if attemptRSSHubRetry(feed: feed, url: url, generation: generation, triggerError: error) {
				return
			}
			reportFeedRefreshError(feed: feed, error: error, activityKind: activityKind)
			return
		}

		let activityOwner = self.activityOwner

		let conditionalGetInfo = HTTPConditionalGetInfo(urlResponse: httpResponse)
		if conditionalGetInfo != feed.conditionalGetInfo {
			Self.logger.debug("LocalAccountRefresher: setting conditionalGetInfo for \(url.absoluteString)")
			feed.conditionalGetInfo = conditionalGetInfo
		}

		guard statusIsOK else {
			// 304 Not Modified
			if let activityOwner {
				ActivityLog.shared.didComplete(activityOwner, kind: activityKind, message: "304 Not Modified", durationIsSignificant: false)
			}
			return
		}

		if let cacheControlInfo = CacheControlInfo(urlResponse: httpResponse) {
			Self.logger.debug("LocalAccountRefresher: setting cacheControlInfo maxAge: \(cacheControlInfo.maxAge) url: \(url.absoluteString)")
			feed.cacheControlInfo = cacheControlInfo
		}

		processFeedData(feed: feed, url: url, data: data, generation: generation)
	}

	/// Parses and stores downloaded data, on either the normal or the fallback
	/// success path. The hash short-circuit applies to both paths.
	///
	/// Deliberate simplification: a 2xx response that cannot be parsed is not
	/// retried, so the first fallback instance returning a 200 error page ends
	/// the candidate chain.
	private func processFeedData(feed: Feed, url: URL, data: Data, generation: Int) {
		let activityKind = ActivityKind.refreshFeedContent(feedURL: feed.url)
		let dataHash = data.md5String
		let dataSizeMessage = ActivityLog.dataSizeMessage(data)
		if dataHash == feed.contentHash {
			if let activityOwner {
				ActivityLog.shared.didComplete(activityOwner, kind: activityKind, message: "\(dataSizeMessage), content unchanged")
			}
			return
		}

		outstandingParseTasks += 1
		Task { @MainActor in
			defer {
				// A stale task belongs to a superseded refresh. That refresh already
				// reset this counter, so leave it alone.
				if generation == self.refreshGeneration {
					self.outstandingParseTasks -= 1
					self.finalizeRefreshIfReady()
				}
			}

			guard generation == self.refreshGeneration else {
				return
			}

			Self.logger.debug("LocalAccountRefresher: parsing feed for \(url.absoluteString)")

			let parserData = ParserData(url: feed.url, data: data)
			let parsedFeed: ParsedFeed
			do {
				guard let result = try await FeedParser.parse(parserData) else {
					guard generation == self.refreshGeneration else {
						return
					}
					if let activityOwner = self.activityOwner {
						ActivityLog.shared.didComplete(activityOwner, kind: activityKind, message: dataSizeMessage)
					}
					return
				}
				parsedFeed = result
			} catch {
				guard generation == self.refreshGeneration else {
					return
				}
				Self.logger.error("LocalAccountRefresher: feed parse error for \(url.absoluteString): \(error.localizedDescription)")
				if let activityOwner = self.activityOwner {
					ActivityLog.shared.didFail(activityOwner, kind: activityKind, error: error)
				}
				self.feedsErrored += 1
				if let account = feed.account {
					let errorLogUserInfo = ErrorLogUserInfoKey.userInfo(sourceName: account.nameForDisplay, sourceID: account.type.rawValue, operation: "Parsing feed", errorMessage: "\(error.localizedDescription): \(url.absoluteString)")
					NotificationCenter.default.post(name: .appDidEncounterError, object: self, userInfo: errorLogUserInfo)
				}
				return
			}

			guard generation == self.refreshGeneration else {
				return
			}
			guard let account = feed.account else {
				if let activityOwner = self.activityOwner {
					ActivityLog.shared.didComplete(activityOwner, kind: activityKind, message: dataSizeMessage)
				}
				return
			}

			assert(Thread.isMainThread)
			let articleChanges = await account.updateAsync(feed: feed, parsedFeed: parsedFeed)

			guard generation == self.refreshGeneration else {
				return
			}

			self.newArticlesCount += articleChanges.new?.count ?? 0
			self.updatedArticlesCount += articleChanges.updated?.count ?? 0

			Self.logger.debug("LocalAccountRefresher: setting contentHash for \(url.absoluteString)")
			feed.contentHash = dataHash

			if let activityOwner = self.activityOwner {
				ActivityLog.shared.didComplete(activityOwner, kind: activityKind, message: dataSizeMessage)
			}

			self.delegate?.localAccountRefresher(self, articleChanges: articleChanges)
		}
	}

	func downloadSession(_ downloadSession: DownloadSession, httpError statusCode: Int, url: URL) {
		guard let feed = urlToFeedDictionary[url.absoluteString] else {
			return
		}
		handleHTTPError(feed: feed, url: url, statusCode: statusCode, generation: refreshGeneration)
	}

	func handleHTTPError(feed: Feed, url: URL, statusCode: Int, generation: Int) {
		guard generation == refreshGeneration else {
			return
		}

		feed.lastCheckDate = Date()
		feed.lastResponseCode = statusCode

		let webserviceError = WebserviceError.httpError(status: statusCode, responseBody: nil)
		let statusDescription = webserviceError.localizedDescription
		let errorMessage = "HTTP \(statusCode) \(statusDescription): \(url.absoluteString)"
		let error = NSError(domain: "NetNewsWire", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])

		if attemptRSSHubRetry(feed: feed, url: url, generation: generation, triggerError: error) {
			return
		}
		reportFeedRefreshError(feed: feed, error: error, activityKind: .refreshFeedContent(feedURL: feed.url))
	}

	private func errorIsConnectivityRelated(_ error: NSError?) -> Bool {
		guard let error, error.domain == NSURLErrorDomain else {
			return false
		}
		let connectivityErrorCodes = [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet]
		return connectivityErrorCodes.contains(error.code)
	}

	private func reportFeedRefreshError(feed: Feed, error: Error, activityKind: ActivityKind) {
		if let activityOwner {
			ActivityLog.shared.didFail(activityOwner, kind: activityKind, error: error)
		}
		feedsErrored += 1
		guard let account = feed.account else {
			return
		}
		let errorLogUserInfo = ErrorLogUserInfoKey.userInfo(sourceName: account.nameForDisplay, sourceID: account.type.rawValue, operation: "Downloading feed: \(feed.url)", errorMessage: AccountError.detailedErrorMessage(error))
		NotificationCenter.default.post(name: .appDidEncounterError, object: self, userInfo: errorLogUserInfo)
	}

	func downloadSession(_ downloadSession: DownloadSession, shouldContinueAfterReceivingData data: Data, url: URL) -> Bool {

		guard !data.isDefinitelyNotFeed(), !isSuspended else {
			return false
		}
		return true
	}

	func downloadSessionDidComplete(_ downloadSession: DownloadSession) {
		downloadSessionIsComplete = true
		finalizeRefreshIfReady()
	}
}

// MARK: - RSSHub Fallback

@MainActor extension LocalAccountRefresher {

	func handleRSSHubFallbackSuccess(feed: Feed, originalURL: URL, data: Data, generation: Int) {
		guard generation == refreshGeneration else {
			return
		}

		feed.lastCheckDate = Date()
		feed.lastResponseCode = 200
		// Drop the original URL's 4xx cache entry, so the next refresh requests it
		// again instead of skipping it and never reaching this fallback.
		downloadSession.clearHTTP4xxResponse(for: originalURL)
		// The fallback instance's conditional-GET and Cache-Control headers do not
		// describe the subscribed URL, so they are deliberately not stored.
		processFeedData(feed: feed, url: originalURL, data: data, generation: generation)
	}

	/// Starts one retry chain for `feed` if it is on a known RSSHub instance.
	/// Returns true when the caller must not report the error: either a chain is
	/// already running or one was started.
	@discardableResult
	func attemptRSSHubRetry(feed: Feed, url: URL, generation: Int, triggerError: Error?) -> Bool {
		guard generation == refreshGeneration, !isSuspended else {
			return false
		}

		// suspend() cancels DownloadSession tasks, which surface here as an
		// NSURLErrorCancelled completion. That is not a transport failure.
		if let triggerError {
			let nsError = triggerError as NSError
			if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
				return false
			}
		}

		if retryingFeedIDs.contains(feed.feedID) {
			return true
		}
		guard !rssHubRetrier.candidateURLs(for: url).isEmpty else {
			return false
		}

		retryingFeedIDs.insert(feed.feedID)
		pendingRSSHubRetries += 1
		let activityKind = ActivityKind.refreshFeedContent(feedURL: feed.url)

		Task { @MainActor in
			defer {
				// A stale chain's result belongs to a superseded refresh, which has
				// already reset the counter.
				if generation == self.refreshGeneration {
					self.pendingRSSHubRetries -= 1
					self.finalizeRefreshIfReady()
				}
			}

			do {
				let result = try await self.rssHubRetrier.fetch(feedURL: url)
				guard generation == self.refreshGeneration else {
					return
				}
				self.handleRSSHubFallbackSuccess(feed: feed, originalURL: url, data: result.data, generation: generation)
			} catch {
				guard generation == self.refreshGeneration else {
					return
				}
				let reportError: Error
				if let triggerError {
					reportError = triggerError
				} else {
					let statusCode = feed.lastResponseCode ?? 0
					reportError = NSError(domain: "LocalAccountRefresher", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode)"])
				}
				self.reportFeedRefreshError(feed: feed, error: reportError, activityKind: activityKind)
			}
		}
		return true
	}
}

// MARK: - Activity Helpers

@MainActor private extension LocalAccountRefresher {

	func completeRefreshActivity(message: String) {
		guard let refreshActivity else {
			return
		}
		ActivityLog.shared.didComplete(id: refreshActivity.id, message: message)
		self.refreshActivity = nil
	}

	/// The single place a refresh is declared finished. Downloads, parse tasks
	/// and RSSHub retry chains all funnel here.
	func finalizeRefreshIfReady() {
		guard downloadSessionIsComplete && outstandingParseTasks == 0 && pendingRSSHubRetries == 0 else {
			return
		}

		if let accountID {
			completeRemainingActivities(accountID: accountID)
		}

		if let refreshActivity, refreshActivity.generation == refreshGeneration {
			ActivityLog.shared.didComplete(id: refreshActivity.id, message: refreshStatsMessage)
			self.refreshActivity = nil
		}

		let completion = self.completion
		self.completion = nil
		if let completion {
			Task { @MainActor in
				completion()
			}
		}
	}

	/// Clean up any leftover per-feed activities at the end of a refresh.
	func completeRemainingActivities(accountID: String) {
		let displayName = AccountManager.shared.existingAccount(accountID: accountID)?.nameForDisplay ?? accountID
		let owner = ActivityOwner.account(accountID: accountID, displayName: displayName)
		let activityLog = ActivityLog.shared

		for activity in activityLog.pendingActivities(for: owner) {
			guard case .refreshFeedContent = activity.kind else {
				continue
			}
			activityLog.startIfNeeded(owner, kind: activity.kind)
			activityLog.didComplete(owner, kind: activity.kind)
		}
		for activity in activityLog.runningActivities(for: owner) {
			guard case .refreshFeedContent = activity.kind else {
				continue
			}
			activityLog.didComplete(owner, kind: activity.kind)
		}
	}

}

// MARK: - Private

private extension LocalAccountRefresher {

	/// These hosts will never return a feed.
	///
	/// People may still have feeds pointing to Twitter due to our prior
	/// use of the Twitter API. (Which Twitter took away.)
	static let badHosts = ["twitter.com", "www.twitter.com", "x.com", "www.x.com"]

	/// Hosts that are exempt from the minimum time between refreshes
	/// even when they don’t send a Cache-Control header.
	///
	/// Feeds that send Cache-Control are already exempt (see
	/// `feedShouldBeSkippedForTimingReasons`); this list is a safety
	/// net for some domains that may or may not send Cache-Control.
	/// The 5-hour Cache-Control cap in
	/// `feedShouldBeSkippedForCacheControlReasons` still applies.
	///
	/// We have permissions from the feed owners for each of these.
	static let domainsWithNoMinimumTime: Set<String> = [
		"inessential.com", "ranchero.com", "netnewswire.blog",
		"daringfireball.net", "redsweater.com", "indiestack.com",
		"blog.plunkitup.com", "bitsplitting.org", "allenpike.com",
		"hypercritical.co", "micro.inessential.com", "discourse.netnewswire.com",
		"onefoottsunami.com", "manton.org", "randsinrepose.com",
		"micro.blog", "shapeof.com", "flyingmeat.com"
	]

	/// Returns whether this feed should be skipped and the reason if so.
	static func feedShouldBeSkipped(_ feed: Feed, _ specialCaseCutoffDate: Date, _ redditURLToRefresh: String?) -> (Bool, String?) {
		let (skipForCacheControl, cacheControlReason) = feedShouldBeSkippedForCacheControlReasons(feed)
		if skipForCacheControl {
			return (true, cacheControlReason)
		}
		let (skipForDisallowedHost, disallowedHostReason) = feedShouldBeSkippedForDisallowedHostReasons(feed)
		if skipForDisallowedHost {
			return (true, disallowedHostReason)
		}
		let (skipForReddit, redditReason) = feedShouldBeSkippedForRedditReasons(feed, redditURLToRefresh)
		if skipForReddit {
			return (true, redditReason)
		}
		let (skipForTiming, timingReason) = feedShouldBeSkippedForTimingReasons(feed, specialCaseCutoffDate)
		if skipForTiming {
			return (true, timingReason)
		}
		return (false, nil)
	}

	/// Reddit rate-limits to one feed per minute, so we
	/// refresh the least recently checked one.
	static func redditURLToRefresh(in feeds: Set<Feed>) -> String? {
		let redditFeeds = feeds.filter { SpecialCase.urlStringMatchesDomain($0.url, [SpecialCase.redditHostName]) }
		let winner = redditFeeds.min { ($0.lastCheckDate ?? .distantPast) < ($1.lastCheckDate ?? .distantPast) }
		return winner?.url
	}

	static func feedShouldBeSkippedForRedditReasons(_ feed: Feed, _ redditURLToRefresh: String?) -> (Bool, String?) {
		guard SpecialCase.urlStringMatchesDomain(feed.url, [SpecialCase.redditHostName]) else {
			return (false, nil)
		}
		if feed.url == redditURLToRefresh {
			return (false, nil)
		}
		var reason = "Skipped — Reddit allows only one feed per minute"
		if let redditURLToRefresh {
			reason += " — refreshing \(redditURLToRefresh) this time"
		}
		return (true, reason)
	}

	static func feedShouldBeSkippedForDisallowedHostReasons(_ feed: Feed) -> (Bool, String?) {
		guard let url = url(for: feed) else {
			return (true, "Skipped — invalid URL")
		}
		guard let lowercaseHost = url.host()?.lowercased() else {
			return (true, "Skipped — no host")
		}

		for badHost in badHosts {
			if lowercaseHost == badHost {
				Self.logger.info("LocalAccountRefresher: Dropping request because it’s X/Twitter, which doesn’t provide feeds: \(feed.url)")
				return (true, "Skipped — host does not provide feeds")
			}
		}

		return (false, nil)
	}

	static let minimumTimeBetweenChecks: TimeInterval = 9 * 60 // 9 minutes

	static func feedShouldBeSkippedForTimingReasons(_ feed: Feed, _ specialCaseCutoffDate: Date) -> (Bool, String?) {
		guard let lastCheckDate = feed.lastCheckDate else {
			return (false, nil)
		}

		// Feeds that send a Cache-Control header are handled elsewhere.
		if feed.cacheControlInfo != nil {
			return (false, nil)
		}

		// Hosts exempt from the minimum time between refreshes.
		if SpecialCase.urlStringMatchesDomain(feed.url, Array(domainsWithNoMinimumTime)) {
			return (false, nil)
		}

		let minutesAgo = Int(Date().timeIntervalSince(lastCheckDate) / 60)
		let minutesAgoText = "\(minutesAgo) minute\(minutesAgo == 1 ? "" : "s") ago"

		if SpecialCase.urlStringContainSpecialCase(feed.url, [SpecialCase.rachelByTheBayHostName, SpecialCase.openRSSOrgHostName]) {
			if lastCheckDate > specialCaseCutoffDate {
				let minimumHours = Int(-specialCaseCutoffDate.timeIntervalSinceNow / 3600)
				let minimumHoursText = "\(minimumHours) hour\(minimumHours == 1 ? "" : "s")"
				Self.logger.info("LocalAccountRefresher: Dropping request for special case timing reasons: \(feed.url)")
				return (true, "Skipped — previous check was \(minutesAgoText) — minimum is \(minimumHoursText)")
			}
		}

		if Date().timeIntervalSince(lastCheckDate) < minimumTimeBetweenChecks {
			let minimumMinutes = Int(minimumTimeBetweenChecks / 60)
			let minimumMinutesText = "\(minimumMinutes) minute\(minimumMinutes == 1 ? "" : "s")"
			Self.logger.info("LocalAccountRefresher: Dropping request — previous check was \(minutesAgoText): \(feed.url)")
			return (true, "Skipped — previous check was \(minutesAgoText) — minimum is \(minimumMinutesText)")
		}

		return (false, nil)
	}

	static let cacheControlMaxMaxAge: TimeInterval = 5 * 60 * 60 // 5 hours

	static let cacheControlTimeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .none
		formatter.timeStyle = .short
		return formatter
	}()

	static func feedShouldBeSkippedForCacheControlReasons(_ feed: Feed) -> (Bool, String?) {
		guard let cacheControlInfo = feed.cacheControlInfo, !cacheControlInfo.canResume else {
			return (false, nil)
		}

		// openrss.org gets unclamped Cache-Control — they configure it correctly.
		if SpecialCase.urlStringContainSpecialCase(feed.url, [SpecialCase.openRSSOrgHostName]) {
			let resumeDate = cacheControlInfo.dateCreated + cacheControlInfo.maxAge
			let readyTime = cacheControlTimeFormatter.string(from: resumeDate)
			Self.logger.info("LocalAccountRefresher: Dropping request for Cache-Control reasons (openrss.org): \(feed.url)")
			return (true, "Skipped — Cache-Control, ready at \(readyTime)")
		}

		// All other feeds: honor Cache-Control with a max max-age
		// because many sites misconfigure it. We’ve seen max-age as
		// long as 16 years (for a feed that updates frequently).
		if !cacheControlInfo.canResume(maxMaxAge: cacheControlMaxMaxAge) {
			let clampedMaxAge = min(cacheControlMaxMaxAge, cacheControlInfo.maxAge)
			let resumeDate = cacheControlInfo.dateCreated + clampedMaxAge
			let readyTime = cacheControlTimeFormatter.string(from: resumeDate)
			Self.logger.info("LocalAccountRefresher: Dropping request for Cache-Control reasons: \(feed.url)")
			return (true, "Skipped — Cache-Control, ready at \(readyTime)")
		}

		return (false, nil)
	}

	static func url(for feed: Feed) -> URL? {
		URL(string: feed.url)
	}
}

// MARK: - Utility

private extension Data {

	func isDefinitelyNotFeed() -> Bool {
		// We only detect a few image types for now. This should get fleshed-out at some later date.
		return self.isImage
	}
}
