//
//  Queue.swift
//  AI
//

import Foundation

/// Retry and lease policy shared by the queue and the SQLite store.
public enum AIQueuePolicy {

	/// How long a claimed job stays leased to its worker.
	public static let leaseDuration: TimeInterval = 5 * 60

	/// Maximum number of attempts before a job is marked failed.
	public static let maxAttempts = 4

	/// Delay before the next attempt, indexed by the attempt that just failed.
	public static let retryDelays: [TimeInterval] = [10 * 60, 30 * 60, 2 * 60 * 60]

	/// Returns the delay before retrying after `attempts` failed attempts,
	/// or nil when the job has exhausted its attempts.
	public static func retryDelay(afterAttempt attempts: Int) -> TimeInterval? {
		guard attempts < maxAttempts else {
			return nil
		}
		let index = max(0, min(attempts - 1, retryDelays.count - 1))
		return retryDelays[index]
	}
}

/// Serial job dispatcher.
///
/// `runOnce` claims at most one job at a time; the actor guarantees that
/// concurrent callers cannot claim the same job. The caller executes the
/// returned job and reports the outcome through the store's `completeJob` /
/// `failJob` methods.
public actor AIQueue {

	private let store: AIStore
	private var isPaused = false

	public init(store: AIStore) {
		self.store = store
	}

	public func enqueue(_ job: AIJob) async throws {
		try await store.enqueue(job)
	}

	public func runOnce(now: Date = Date(), allowedKinds: [AIJobKind]? = nil) async throws -> AIJob? {
		guard !isPaused else {
			return nil
		}
		return try await store.claimNextJob(now: now, allowedKinds: allowedKinds)
	}

	public func pause() {
		isPaused = true
	}

	public func resume() {
		isPaused = false
	}
}
