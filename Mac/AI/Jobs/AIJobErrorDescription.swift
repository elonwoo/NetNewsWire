//
//  AIJobErrorDescription.swift
//  NetNewsWire
//

import AI
import Foundation

enum AIJobErrorDescription {

	static func describe(_ error: Error) -> String {
		if let engineError = error as? AIEngineError {
			switch engineError {
			case .emptyContent:
				return AILocalization.string("Article content is empty")
			case .invalidModelResponse(let detail):
				return AILocalization.format("Invalid model response format: %@", detail)
			case .incompleteTranslation(let missing):
				let indices = missing.map(String.init).joined(separator: ", ")
				return AILocalization.format("Translation is missing blocks: %@", indices)
			}
		}

		if let rewriteError = error as? AIRewriteError {
			switch rewriteError {
			case .qualityRejected(let reason):
				return AILocalization.format("Rewrite quality check failed: %@", reason)
			}
		}

		if let clientError = error as? AIClientError {
			switch clientError {
			case .invalidResponse:
				return AILocalization.string("Invalid model response")
			case .httpStatus(let code):
				return AILocalization.format("Model request failed (HTTP %lld)", code)
			case .missingContent:
				return AILocalization.string("Model response is missing content")
			case .emptyContent:
				return AILocalization.string("Model returned empty content")
			case .truncated:
				return AILocalization.string("Model output was truncated")
			}
		}

		return error.localizedDescription
	}
}
