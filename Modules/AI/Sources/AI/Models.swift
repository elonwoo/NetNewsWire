//
//  Models.swift
//  AI
//

import Foundation

public struct AIArticle: Sendable, Equatable {
	public let id: String
	public let title: String
	public let contentHTML: String?
	public let contentText: String?
	public let url: String?
	public let feedID: String?
	public let publishedAt: Date?
	public let isRead: Bool

	public init(id: String, title: String, contentHTML: String? = nil, contentText: String? = nil, url: String? = nil, feedID: String? = nil, publishedAt: Date? = nil, isRead: Bool = false) {
		self.id = id
		self.title = title
		self.contentHTML = contentHTML
		self.contentText = contentText
		self.url = url
		self.feedID = feedID
		self.publishedAt = publishedAt
		self.isRead = isRead
	}

	/// True when the article has text or HTML to translate or rewrite. A feed
	/// that only ships a title cannot produce a body translation or a rewrite.
	public var hasBody: Bool {
		if let contentText, !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		if let contentHTML, !contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		return false
	}
}

public struct TranslationBlock: Codable, Sendable, Equatable {
	public let index: Int
	public let source: String
	public let target: String
	public let targetHTML: String?

	public init(index: Int, source: String, target: String, targetHTML: String? = nil) {
		self.index = index
		self.source = source
		self.target = target
		self.targetHTML = targetHTML
	}
}

public struct Translation: Codable, Sendable, Equatable {
	public let articleID: String
	public let titleZh: String?
	public let summaryZh: String?
	public let blocks: [TranslationBlock]
	public let model: String
	public let provider: String
	public let contentHash: String
	public let createdAt: Date
	public let updatedAt: Date

	public init(articleID: String, titleZh: String? = nil, summaryZh: String? = nil, blocks: [TranslationBlock], model: String, provider: String, contentHash: String, createdAt: Date, updatedAt: Date) {
		self.articleID = articleID
		self.titleZh = titleZh
		self.summaryZh = summaryZh
		self.blocks = blocks
		self.model = model
		self.provider = provider
		self.contentHash = contentHash
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}
}

public struct Rewrite: Codable, Sendable, Equatable {
	public let articleID: String
	public let title: String
	public let bodyMarkdown: String
	public let bodyHTML: String?
	public let model: String
	public let contentHash: String
	public let createdAt: Date
	public let updatedAt: Date

	public init(articleID: String, title: String, bodyMarkdown: String, bodyHTML: String? = nil, model: String, contentHash: String, createdAt: Date, updatedAt: Date) {
		self.articleID = articleID
		self.title = title
		self.bodyMarkdown = bodyMarkdown
		self.bodyHTML = bodyHTML
		self.model = model
		self.contentHash = contentHash
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}
}

public enum ChatRole: String, Codable, Sendable {
	case user
	case assistant
}

public struct ChatMessage: Codable, Sendable, Equatable {
	public let id: String
	public let articleID: String
	public let role: ChatRole
	public let content: String
	public let model: String?
	public let createdAt: Date

	public init(id: String, articleID: String, role: ChatRole, content: String, model: String? = nil, createdAt: Date) {
		self.id = id
		self.articleID = articleID
		self.role = role
		self.content = content
		self.model = model
		self.createdAt = createdAt
	}
}

public enum AIJobKind: String, Codable, Sendable {
	case titleTranslation
	case bodyTranslation
	case rewrite
}

public enum AIJobStatus: String, Codable, Sendable {
	case pending
	case running
	case retry
	case completed
	case failed
}

public struct AIJob: Codable, Sendable, Equatable {
	public let id: String
	public let articleID: String
	public let kind: AIJobKind
	public let priority: Int
	public var status: AIJobStatus
	public var attempts: Int
	public var availableAt: Date
	public var leaseUntil: Date?
	public var lastError: String?
	public let createdAt: Date

	public init(id: String, articleID: String, kind: AIJobKind, priority: Int, status: AIJobStatus = .pending, attempts: Int = 0, availableAt: Date, leaseUntil: Date? = nil, lastError: String? = nil, createdAt: Date) {
		self.id = id
		self.articleID = articleID
		self.kind = kind
		self.priority = priority
		self.status = status
		self.attempts = attempts
		self.availableAt = availableAt
		self.leaseUntil = leaseUntil
		self.lastError = lastError
		self.createdAt = createdAt
	}
}
