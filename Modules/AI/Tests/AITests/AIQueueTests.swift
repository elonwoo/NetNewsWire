//
//  AIQueueTests.swift
//  AITests
//

import Foundation
import Testing
@testable import AI

@Suite final class AIQueueTests {

	private let store: SQLiteAIStore
	private let queue: AIQueue
	private let databasePath: String

	init() {
		self.databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIQueueTests-\(UUID().uuidString).sqlite")
			.path
		let store = SQLiteAIStore(databasePath: databasePath)
		self.store = store
		self.queue = AIQueue(store: store)
	}

	deinit {
		let fileManager = FileManager.default
		try? fileManager.removeItem(atPath: databasePath)
		try? fileManager.removeItem(atPath: databasePath + "-wal")
		try? fileManager.removeItem(atPath: databasePath + "-shm")
	}

	@Test func claimsJobAndLeasesItForFiveMinutes() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		let job = makeJob(id: "job-1", availableAt: now)
		try await queue.enqueue(job)

		let claimed = try #require(try await queue.runOnce(now: now))
		#expect(claimed.id == "job-1")
		#expect(claimed.status == .running)
		#expect(claimed.attempts == 1)
		#expect(claimed.leaseUntil == now.addingTimeInterval(5 * 60))

		#expect(try await queue.runOnce(now: now) == nil)
		#expect(try await queue.runOnce(now: now.addingTimeInterval(5 * 60 - 1)) == nil)
	}

	@Test func reclaimsJobAfterLeaseExpires() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		try await queue.enqueue(makeJob(id: "job-1", availableAt: now))

		_ = try #require(try await queue.runOnce(now: now))
		let reclaimed = try #require(try await queue.runOnce(now: now.addingTimeInterval(5 * 60)))
		#expect(reclaimed.id == "job-1")
		#expect(reclaimed.attempts == 2)
	}

	@Test func failedJobIsNotClaimedBeforeRetryTime() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		try await queue.enqueue(makeJob(id: "job-1", availableAt: now))

		let claimed = try #require(try await queue.runOnce(now: now))
		try await store.failJob(id: claimed.id, error: "boom", retryAt: now.addingTimeInterval(10 * 60))

		#expect(try await queue.runOnce(now: now.addingTimeInterval(10 * 60 - 1)) == nil)
		let retried = try #require(try await queue.runOnce(now: now.addingTimeInterval(10 * 60)))
		#expect(retried.id == "job-1")
		#expect(retried.attempts == 2)
	}

	@Test func retriesFollowTheBackoffScheduleUntilExhausted() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		try await queue.enqueue(makeJob(id: "job-1", availableAt: now))

		let first = try #require(try await queue.runOnce(now: now))
		#expect(first.attempts == 1)
		// failJob schedules the retry off the real clock, so the retry window
		// here is anchored to Date() with a minute of slack on each side.
		try await store.failJob(id: first.id, error: "first", retryAt: nil)

		#expect(try await queue.runOnce(now: Date().addingTimeInterval(9 * 60)) == nil)
		let second = try #require(try await queue.runOnce(now: Date().addingTimeInterval(11 * 60)))
		#expect(second.attempts == 2)
		try await store.failJob(id: second.id, error: "second", retryAt: nil)

		#expect(try await queue.runOnce(now: Date().addingTimeInterval(60 * 60 * 24)) == nil)
	}

	@Test func completedJobIsNeverClaimedAgain() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		try await queue.enqueue(makeJob(id: "job-1", availableAt: now))

		let claimed = try #require(try await queue.runOnce(now: now))
		try await store.completeJob(id: claimed.id)

		#expect(try await queue.runOnce(now: now.addingTimeInterval(60 * 60)) == nil)
	}

	@Test func higherPriorityJobIsClaimedFirst() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		try await queue.enqueue(makeJob(id: "low", priority: 0, availableAt: now))
		try await queue.enqueue(makeJob(id: "high", priority: 10, availableAt: now))

		let first = try #require(try await queue.runOnce(now: now))
		#expect(first.id == "high")
		let second = try #require(try await queue.runOnce(now: now))
		#expect(second.id == "low")
	}

	@Test func pauseStopsClaimingUntilResume() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		try await queue.enqueue(makeJob(id: "job-1", availableAt: now))

		await queue.pause()
		#expect(try await queue.runOnce(now: now) == nil)

		await queue.resume()
		let claimed = try #require(try await queue.runOnce(now: now))
		#expect(claimed.id == "job-1")
	}

	@Test func concurrentClaimsNeverReturnTheSameJob() async throws {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		for index in 0..<10 {
			try await store.enqueue(makeJob(id: "job-\(index)", availableAt: now))
		}

		let store = self.store
		let claimedIDs = await withTaskGroup(of: String?.self, returning: [String].self) { group in
			for _ in 0..<10 {
				group.addTask {
					guard let job = try? await store.claimNextJob(now: now) else {
						return nil
					}
					return job.id
				}
			}
			var ids: [String] = []
			for await id in group {
				if let id {
					ids.append(id)
				}
			}
			return ids
		}

		#expect(claimedIDs.count == 10)
		#expect(Set(claimedIDs).count == 10)
	}

	@Test func retryPolicyMatchesTheDocumentedSchedule() {
		#expect(AIQueuePolicy.leaseDuration == 5 * 60)
		#expect(AIQueuePolicy.maxAttempts == 2)
		#expect(AIQueuePolicy.retryDelay(afterAttempt: 1) == 10.0 * 60)
		#expect(AIQueuePolicy.retryDelay(afterAttempt: 2) == nil)
	}
}

private extension AIQueueTests {

	func makeJob(id: String, priority: Int = 0, availableAt: Date) -> AIJob {
		AIJob(id: id, articleID: "article-\(id)", kind: .titleTranslation, priority: priority, availableAt: availableAt, createdAt: availableAt)
	}
}
