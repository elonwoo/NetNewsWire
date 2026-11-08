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
				return "文章内容为空"
			case .invalidModelResponse(let detail):
				return "模型返回格式无效：\(detail)"
			case .incompleteTranslation(let missing):
				let indices = missing.map(String.init).joined(separator: ", ")
				return "译文缺少块：\(indices)"
			}
		}

		if let rewriteError = error as? AIRewriteError {
			switch rewriteError {
			case .qualityRejected(let reason):
				return "改写质量校验失败：\(reason)"
			}
		}

		if let clientError = error as? AIClientError {
			switch clientError {
			case .invalidResponse:
				return "模型响应无效"
			case .httpStatus(let code):
				return "模型请求失败（HTTP \(code)）"
			case .missingContent:
				return "模型响应缺少内容"
			case .emptyContent:
				return "模型返回空内容"
			case .truncated:
				return "模型输出被截断"
			}
		}

		return error.localizedDescription
	}
}
