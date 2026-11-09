//
//  AIChineseCleanup.swift
//  NetNewsWire
//

import Account
import AI
import Foundation
import os

/// One-time cleanup for the Chinese-AI rule.
///
/// Chinese articles no longer get rewrites or translations, so their cached
/// rows and unfinished jobs are removed. English caches, completed/failed job
/// history and chat messages stay. The routine is deterministic and injectable
/// so tests can run it against a temporary database without touching the live
/// account graph.
struct AIChineseCleanupResult: Equatable, Sendable {
	let succeeded: Bool
	let performed: Bool
	let chineseArticleCount: Int
	let deletedRewriteCount: Int
	let deletedTranslationCount: Int
	let deletedJobCount: Int
	let backupPath: String
}

struct AIChineseCleanupSource: Sendable {

	struct AccountArticles: Sendable {
		let accountID: String
		let articles: [AIArticle]
	}

	let accounts: [AccountArticles]
}

enum AIChineseCleanup {

	static let didRunKey = "AI.DidCleanChineseArtifacts"

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AIChineseCleanup")
	private static let backupDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return formatter
	}()

	/// The app-side entry point. Runs once, before the job executor starts, and
	/// records completion only after the whole cleanup, including the backup
	/// verification, succeeds.
	@MainActor
	static func runIfNeeded() async {
		guard !UserDefaults.standard.bool(forKey: didRunKey) else {
			return
		}
		let source = await liveSource()
		let backupPath = "/tmp/AI.sqlite.before-zh-cleanup.\(backupDateFormatter.string(from: Date())).db"
		let result = await run(store: AIEnvironment.shared.store, backupPath: backupPath, source: source, log: { message in
			logger.info("\(message, privacy: .public)")
		})
		guard result.succeeded else {
			logger.error("AI Chinese cleanup failed; it will retry on the next launch")
			return
		}
		UserDefaults.standard.set(true, forKey: didRunKey)
		logger.info("AI Chinese cleanup finished; backup at \(result.backupPath, privacy: .public)")
	}

	/// The cleanup routine itself. `source` supplies every article across every
	/// account; `backupVerifier` is the self-check hook that must accept the
	/// backup before anything is deleted.
	static func run(
		store: SQLiteAIStore,
		backupPath: String,
		source: AIChineseCleanupSource,
		backupVerifier: @Sendable (AIArtifactInventory, AIArtifactInventory) -> Bool = { $0 == $1 },
		log: @Sendable (String) -> Void = { _ in }
	) async -> AIChineseCleanupResult {
		var chineseArticleIDs = Set<String>()
		var totalArticleCount = 0
		for account in source.accounts {
			var chineseCount = 0
			var nonChineseCount = 0
			var emptySampleCount = 0
			for article in account.articles {
				totalArticleCount += 1
				if !AutoWorkPolicy.hasLanguageSample(article) {
					emptySampleCount += 1
					nonChineseCount += 1
				} else if AutoWorkPolicy.isChinese(article) {
					chineseCount += 1
					chineseArticleIDs.insert(article.id)
				} else {
					nonChineseCount += 1
				}
			}
			log("AI cleanup account \(account.accountID): total \(account.articles.count), Chinese \(chineseCount), non-Chinese \(nonChineseCount), empty sample \(emptySampleCount)")
		}
		log("AI cleanup total articles \(totalArticleCount), Chinese article IDs \(chineseArticleIDs.count)")

		func failure(_ message: String) -> AIChineseCleanupResult {
			log("AI cleanup aborted: \(message)")
			return AIChineseCleanupResult(
				succeeded: false,
				performed: false,
				chineseArticleCount: chineseArticleIDs.count,
				deletedRewriteCount: 0,
				deletedTranslationCount: 0,
				deletedJobCount: 0,
				backupPath: backupPath
			)
		}

		do {
			let before = try await store.inventory()
			let chineseRewrites = before.rewriteArticleIDs.intersection(chineseArticleIDs)
			let chineseTranslations = before.translationArticleIDs.intersection(chineseArticleIDs)
			let englishRewrites = before.rewriteArticleIDs.subtracting(chineseArticleIDs)
			let englishTranslations = before.translationArticleIDs.subtracting(chineseArticleIDs)
			let chineseActiveJobs = before.activeJobArticleIDs.intersection(chineseArticleIDs)
			log("AI cleanup before: rewrites Chinese \(chineseRewrites.count) / English \(englishRewrites.count), translations Chinese \(chineseTranslations.count) / English \(englishTranslations.count), active jobs Chinese \(chineseActiveJobs.count) / English \(before.activeJobArticleIDs.subtracting(chineseArticleIDs).count), completed jobs \(before.completedJobArticleIDs.count), failed jobs \(before.failedJobArticleIDs.count), chat messages \(before.chatMessageCount)")

			guard !chineseArticleIDs.isEmpty else {
				// Nothing to delete, but record a successful pass so the migration
				// does not run again.
				log("AI cleanup: no Chinese articles; nothing to delete")
				return AIChineseCleanupResult(succeeded: true, performed: false, chineseArticleCount: 0, deletedRewriteCount: 0, deletedTranslationCount: 0, deletedJobCount: 0, backupPath: backupPath)
			}

			guard !FileManager.default.fileExists(atPath: backupPath) else {
				return failure("backup path already exists: \(backupPath)")
			}
			try await store.vacuumInto(backupPath)
			let backupStore = SQLiteAIStore(databasePath: backupPath)
			let backupInventory = try await backupStore.inventory()
			guard backupVerifier(before, backupInventory) else {
				return failure("backup counts do not match the source database")
			}
			log("AI cleanup backup verified at \(backupPath)")

			let deletion = try await store.deleteActiveAIArtifacts(articleIDs: chineseArticleIDs)
			log("AI cleanup deleted rewrites \(deletion.rewriteCount), translations \(deletion.translationCount), unfinished jobs \(deletion.jobCount)")

			let after = try await store.inventory()
			let checks: [(String, Bool)] = [
				("Chinese rewrites removed", after.rewriteArticleIDs.intersection(chineseArticleIDs).isEmpty),
				("Chinese translations removed", after.translationArticleIDs.intersection(chineseArticleIDs).isEmpty),
				("Chinese unfinished jobs removed", after.activeJobArticleIDs.intersection(chineseArticleIDs).isEmpty),
				("English rewrites unchanged", after.rewriteArticleIDs.subtracting(chineseArticleIDs) == englishRewrites),
				("English translations unchanged", after.translationArticleIDs.subtracting(chineseArticleIDs) == englishTranslations),
				("English active jobs unchanged", after.activeJobArticleIDs.subtracting(chineseArticleIDs) == before.activeJobArticleIDs.subtracting(chineseArticleIDs)),
				("Completed job history unchanged", after.completedJobArticleIDs == before.completedJobArticleIDs),
				("Failed job history unchanged", after.failedJobArticleIDs == before.failedJobArticleIDs),
				("Chat messages unchanged", after.chatMessageCount == before.chatMessageCount)
			]
			let failedChecks = checks.filter { !$0.1 }.map(\.0)
			guard failedChecks.isEmpty else {
				return failure("post-delete verification failed: \(failedChecks.joined(separator: ", "))")
			}
			log("AI cleanup verified: Chinese rewrites 0, Chinese translations 0, English caches and job history unchanged")

			return AIChineseCleanupResult(
				succeeded: true,
				performed: true,
				chineseArticleCount: chineseArticleIDs.count,
				deletedRewriteCount: deletion.rewriteCount,
				deletedTranslationCount: deletion.translationCount,
				deletedJobCount: deletion.jobCount,
				backupPath: backupPath
			)
		} catch {
			return failure(String(describing: error))
		}
	}
}

private extension AIChineseCleanup {

	@MainActor
	static func liveSource() async -> AIChineseCleanupSource {
		var accounts: [AIChineseCleanupSource.AccountArticles] = []
		for account in AccountManager.shared.accounts {
			var articles: [AIArticle] = []
			for feed in account.flattenedFeeds() {
				for article in await feed.fetchArticlesAsync() {
					articles.append(AIArticle(article: article))
				}
			}
			accounts.append(AIChineseCleanupSource.AccountArticles(accountID: account.accountID, articles: articles))
		}
		return AIChineseCleanupSource(accounts: accounts)
	}
}
