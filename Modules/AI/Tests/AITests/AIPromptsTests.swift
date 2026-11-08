//
//  AIPromptsTests.swift
//  AITests
//

import Testing
@testable import AI

@Suite final class AIPromptsTests {

	@Test func readingTasksHaveTwelveEntriesInTheExpectedOrder() {
		#expect(AIPrompts.readingTasks.count == 12)
		#expect(AIPrompts.readingTasks.map(\.group) == [
			"理解", "理解",
			"核查", "核查",
			"反驳", "反驳",
			"行动", "行动",
			"写作", "写作",
			"延伸", "延伸"
		])
		#expect(AIPrompts.readingTasks.map(\.label) == [
			"总结要点", "结构拆解",
			"事实清单", "待验证点",
			"反方观点", "前提测试",
			"行动建议", "产品机会",
			"分享文案", "选题角度",
			"延伸阅读", "关联概念"
		])
	}

	@Test func readingTaskPromptsAreNonEmpty() {
		for task in AIPrompts.readingTasks {
			#expect(!task.group.isEmpty)
			#expect(!task.label.isEmpty)
			#expect(!task.prompt.isEmpty)
		}
	}

	@Test func selectionAngleTaskUsesNeutralWording() throws {
		let task = try #require(AIPrompts.readingTasks.first { $0.label == "选题角度" })
		#expect(task.prompt == "如果要基于这篇文章写一篇中文内容，最有传播潜力的切入角度有哪些？给 3 个。")
	}

	@Test func promptsContainNoPersonaReferences() {
		var prompts = [
			AIPrompts.terminologyRule,
			AIPrompts.rewriteArticle,
			AIPrompts.rewritePaper,
			AIPrompts.rewriteProductHunt,
			AIPrompts.titleTranslationSystem,
			AIPrompts.bodyTranslationSystem,
			AIPrompts.chatSystem
		]
		prompts.append(contentsOf: AIPrompts.readingTasks.map(\.prompt))

		for prompt in prompts {
			#expect(!prompt.contains("乔木"))
			#expect(!prompt.lowercased().contains("qiaomu"))
		}
	}

	@Test func rewritePromptsUseNeutralOpening() {
		#expect(AIPrompts.rewriteArticle.hasPrefix("你是一位中文科技内容作者。"))
		#expect(AIPrompts.rewritePaper.hasPrefix("你是一位中文科技内容作者。"))
		#expect(AIPrompts.rewriteProductHunt.hasPrefix("你是一位中文科技内容作者。"))
		#expect(AIPrompts.rewritePaper.contains("值得追问的方向"))
		#expect(AIPrompts.rewritePaper.contains("写作风格："))
		#expect(!AIPrompts.rewritePaper.contains("乔木写作风格"))
	}

	@Test func productHuntPromptExtendsTheArticlePrompt() {
		#expect(AIPrompts.rewriteProductHunt.contains(AIPrompts.rewriteArticle))
		#expect(AIPrompts.rewriteProductHunt.contains("Product Hunt 产品改写补充要求："))
		#expect(!AIPrompts.rewriteProductHunt.contains("Hacker News"))
		#expect(!AIPrompts.rewriteProductHunt.contains("播客"))
	}
}
