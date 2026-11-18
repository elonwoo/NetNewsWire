//
//  AIJobFailureClassifierTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

/// The retry policy gives every job exactly one scheduled retry, so the
/// classifier decides which failures are worth it. Deterministic failures
/// (timeouts, bad model output, quality rejections) must be permanent;
/// only flaky-network failures stay retryable.
struct AIJobFailureClassifierTests {

	// MARK: - URL errors

	@Test func requestTimeoutsArePermanent() {
		#expect(AIJobFailureClassifier.classify(URLError(.timedOut)) == .permanent)
	}

	@Test func networkURLErrorsAreRetryable() {
		let codes: [URLError.Code] = [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed]
		for code in codes {
			#expect(AIJobFailureClassifier.classify(URLError(code)) == .retryable)
		}
	}

	@Test func urlCancellationIsRetryable() {
		#expect(AIJobFailureClassifier.classify(URLError(.cancelled)) == .retryable)
		#expect(AIJobFailureClassifier.classify(CancellationError()) == .retryable)
	}

	// MARK: - HTTP status

	@Test func requestTimeoutStatusIsPermanent() {
		#expect(AIJobFailureClassifier.classify(AIClientError.httpStatus(408)) == .permanent)
	}

	@Test func throttlingAndServerErrorsAreRetryable() {
		for status in [429, 500, 502, 503, 504] {
			#expect(AIJobFailureClassifier.classify(AIClientError.httpStatus(status)) == .retryable)
		}
	}

	@Test func otherClientErrorsArePermanent() {
		for status in [400, 401, 403, 404, 422] {
			#expect(AIJobFailureClassifier.classify(AIClientError.httpStatus(status)) == .permanent)
		}
	}

	// MARK: - Client payload errors

	@Test func malformedClientResponsesArePermanent() {
		let errors: [AIClientError] = [.invalidResponse, .missingContent, .emptyContent, .truncated]
		for error in errors {
			#expect(AIJobFailureClassifier.classify(error) == .permanent)
		}
	}

	// MARK: - Engine and rewrite

	@Test func engineErrorsArePermanent() {
		let errors: [AIEngineError] = [
			.emptyContent,
			.invalidModelResponse("not json"),
			.incompleteTranslation(missing: [2])
		]
		for error in errors {
			#expect(AIJobFailureClassifier.classify(error) == .permanent)
		}
	}

	@Test func rewriteQualityRejectionIsPermanent() {
		#expect(AIJobFailureClassifier.classify(AIRewriteError.qualityRejected("too short")) == .permanent)
	}

	// MARK: - Unknown errors

	@Test func unknownErrorsStayRetryable() {
		struct MysteryError: Error {}
		#expect(AIJobFailureClassifier.classify(MysteryError()) == .retryable)
	}
}
