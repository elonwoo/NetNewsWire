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
/// Deterministic failures — timeouts, malformed model output, quality
/// rejections — re-fail on the same input, so they end after the first attempt.
/// Only network flakiness and cancellation keep the one retry that
/// `AIQueuePolicy` schedules.
enum AIJobFailureClassifier {

	static func classify(_ error: Error) -> AIJobFailureKind {
		if let urlError = error as? URLError {
			// A 240s request timeout means the input is too slow for the model at
			// its current speed; a second attempt spends the same time again.
			return urlError.code == .timedOut ? .permanent : .retryable
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
