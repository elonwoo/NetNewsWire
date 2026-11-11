//
//  AICustomPromptStoreTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing
@testable import NetNewsWire

@MainActor
@Suite final class AICustomPromptStoreTests {

	private static let defaultsKey = "aiCustomPrompts"

	@Test func migratesLegacyStringPrompts() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let legacy = "Summarize the key points of this article in five bullets"
		defaults.set([legacy], forKey: Self.defaultsKey)

		let store = AICustomPromptStore(defaults: defaults)

		try #require(store.prompts.count == 1)
		#expect(store.prompts[0].name == "Summarize the key po")
		#expect(store.prompts[0].prompt == legacy)
	}

	@Test func migrationRewritesNewFormatWithoutDuplicating() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let legacy = "Summarize the key points of this article in five bullets"
		defaults.set([legacy], forKey: Self.defaultsKey)

		_ = AICustomPromptStore(defaults: defaults)
		let stored = try #require(defaults.array(forKey: Self.defaultsKey) as? [[String: String]])
		try #require(stored.count == 1)
		#expect(stored[0]["name"] == "Summarize the key po")
		#expect(stored[0]["prompt"] == legacy)

		let reloaded = AICustomPromptStore(defaults: defaults)
		try #require(reloaded.prompts.count == 1)
		#expect(reloaded.prompts[0].prompt == legacy)
	}

	@Test func addUpdateRemove() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AICustomPromptStore(defaults: defaults)

		#expect(store.add(name: "概括", prompt: "用一句话概括文章。"))
		try #require(store.prompts.count == 1)
		#expect(store.prompts[0].name == "概括")
		#expect(store.prompts[0].prompt == "用一句话概括文章。")

		#expect(store.update(at: 0, name: "翻译", prompt: "把最后一段翻译成中文。"))
		#expect(store.prompts[0].name == "翻译")
		#expect(store.prompts[0].prompt == "把最后一段翻译成中文。")

		store.remove(at: 0)
		#expect(store.prompts.isEmpty)
	}

	@Test func rejectsDuplicateName() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AICustomPromptStore(defaults: defaults)

		#expect(store.add(name: "概括", prompt: "内容一"))
		#expect(!store.add(name: "概括", prompt: "内容二"))
		#expect(store.prompts.count == 1)
	}

	@Test func updateRejectsAnotherPromptsName() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AICustomPromptStore(defaults: defaults)

		#expect(store.add(name: "概括", prompt: "内容一"))
		#expect(store.add(name: "翻译", prompt: "内容二"))
		#expect(!store.update(at: 0, name: "翻译", prompt: "内容三"))
		#expect(store.update(at: 0, name: "概括", prompt: "内容三"))
	}

	@Test func rejectsEmptyNameOrPrompt() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AICustomPromptStore(defaults: defaults)

		#expect(!store.add(name: "  ", prompt: "内容"))
		#expect(!store.add(name: "名称", prompt: "  "))
		#expect(store.prompts.isEmpty)
	}

	@Test func acceptsNameAndPromptAtMaximumLength() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AICustomPromptStore(defaults: defaults)

		let name = String(repeating: "名", count: 20)
		let prompt = String(repeating: "文", count: 1000)

		#expect(store.add(name: name, prompt: prompt))
		try #require(store.prompts.count == 1)
		#expect(store.prompts[0].name == name)
		#expect(store.prompts[0].prompt == prompt)
	}

	@Test func rejectsNameAndPromptOverMaximumLength() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AICustomPromptStore(defaults: defaults)

		let overlongName = String(repeating: "名", count: 21)
		let overlongPrompt = String(repeating: "文", count: 1001)

		#expect(!store.add(name: overlongName, prompt: "内容"))
		#expect(!store.add(name: "名称", prompt: overlongPrompt))
		#expect(store.prompts.isEmpty)
	}

	@Test func respectsMaximumCount() throws {
		let (defaults, suiteName) = try makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AICustomPromptStore(defaults: defaults)

		for index in 0..<AICustomPromptStore.maximumCount {
			#expect(store.add(name: "名称\(index)", prompt: "内容\(index)"))
		}
		#expect(store.prompts.count == AICustomPromptStore.maximumCount)
		#expect(!store.add(name: "再来一条", prompt: "内容"))
		#expect(store.prompts.count == AICustomPromptStore.maximumCount)
	}

	private func makeDefaults() throws -> (UserDefaults, String) {
		let suiteName = "AICustomPromptStoreTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suiteName))
		defaults.removePersistentDomain(forName: suiteName)
		return (defaults, suiteName)
	}
}
