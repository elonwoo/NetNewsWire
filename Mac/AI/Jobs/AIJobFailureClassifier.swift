//
//  AIJobFailureClassifier.swift
//  NetNewsWire
//

import AI
import Foundation

/// Whether a failed AI job deserves the single scheduled retry.
enum AIJobFailureKind: Sendable, Equatable {
	case permanent
	case retryable
}

/// Sorts a failure into deterministic and transient kinds.
///
/// Deterministic failures — malformed model output, quality rejections —
/// re-fail on the same input, so they end after the first attempt. Network
/// trouble behaves like flakiness and keeps the one retry that
/// `AIQueuePolicy` schedules; that includes the 240s request timeout, which
/// fires in batches when the local gateway is congested.
enum AIJobFailureClassifier {

	static func classify(_ error: Error) -> AIJobFailureKind {
		if error is URLError {
			// In-flight and queued requests hit their timeout together when the
			// gateway backs up; the 600s retry lets that backlog drain instead
			// of ending every job at once.
			return .retryable
		}
		if error is CancellationError {
			// Cancellation usually comes from app shutdown; a retry row is picked
			// up on the next launch.
			return .retryable
		}
		if let clientError = error as? AIClientError {
			switch clientError {
			case .httpStatus(let status):
				if status == 408 {
					return .permanent
				}
				if status == 429 || (500...599).contains(status) {
					return .retryable
				}
				return .permanent
			case .invalidResponse, .missingContent, .emptyContent, .truncated:
				return .permanent
			}
		}
		if error is AIEngineError {
			return .permanent
		}
		if error is AIRewriteError {
			return .permanent
		}
		return .retryable
	}
}
