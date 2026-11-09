//
//  AIEnqueueReservations.swift
//  NetNewsWire
//

import Foundation

/// Jobs that have been reserved locally but not yet handed to the queue.
///
/// A reservation happens synchronously, before the first `await` of an enqueue
/// path, so two callers arriving in the same run loop turn cannot both decide
/// that a job is missing and queue it twice. Every early exit and every queue
/// failure must release the reservation.
struct AIEnqueueReservations {

	private var keys = Set<String>()

	func contains(_ key: String) -> Bool {
		keys.contains(key)
	}

	/// Reserves the key. Returns false when it was already reserved.
	mutating func reserve(_ key: String) -> Bool {
		keys.insert(key).inserted
	}

	mutating func release(_ key: String) {
		keys.remove(key)
	}

	mutating func removeAll(where shouldRemove: (String) -> Bool) {
		keys = Set(keys.filter { !shouldRemove($0) })
	}
}
