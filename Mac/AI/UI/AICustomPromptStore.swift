//
//  AICustomPromptStore.swift
//  NetNewsWire
//

import Foundation

/// A user-written chat prompt, made of a short display name and the content sent to the model.
struct AICustomPrompt {
	let name: String
	let prompt: String
}

/// Keeps user-written chat prompts in UserDefaults, capped at 24 entries.
@MainActor
final class AICustomPromptStore {

	static let maximumCount = 24
	static let maximumNameLength = 20
	static let maximumPromptLength = 1000

	private static let defaultsKey = "aiCustomPrompts"

	private let defaults: UserDefaults
	private(set) var prompts: [AICustomPrompt] = []

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		reload()
	}

	func reload() {
		guard let stored = defaults.array(forKey: Self.defaultsKey) else {
			prompts = []
			return
		}

		if let legacyPrompts = stored as? [String] {
			prompts = Array(legacyPrompts.compactMap(Self.migratedPrompt(from:)).prefix(Self.maximumCount))
			persist()
			return
		}

		if let storedPrompts = stored as? [[String: String]] {
			prompts = Array(storedPrompts.compactMap(Self.prompt(from:)).prefix(Self.maximumCount))
		} else {
			prompts = []
		}
	}

	/// Adds a prompt. Returns false when the name or content is invalid, the name is
	/// already taken, or the list is full.
	@discardableResult
	func add(name: String, prompt: String) -> Bool {
		guard prompts.count < Self.maximumCount, let validated = Self.validatedPrompt(name: name, prompt: prompt) else {
			return false
		}
		guard !prompts.contains(where: { $0.name == validated.name }) else {
			return false
		}
		prompts.append(validated)
		persist()
		return true
	}

	/// Replaces the prompt at `index`. Returns false when the index is invalid, the new
	/// values are invalid, or the name is used by another prompt.
	@discardableResult
	func update(at index: Int, name: String, prompt: String) -> Bool {
		guard prompts.indices.contains(index), let validated = Self.validatedPrompt(name: name, prompt: prompt) else {
			return false
		}
		let isDuplicate = prompts.enumerated().contains { offset, existing in
			offset != index && existing.name == validated.name
		}
		guard !isDuplicate else {
			return false
		}
		prompts[index] = validated
		persist()
		return true
	}

	func remove(at index: Int) {
		guard prompts.indices.contains(index) else {
			return
		}
		prompts.remove(at: index)
		persist()
	}

	private func persist() {
		let stored = prompts.map { ["name": $0.name, "prompt": $0.prompt] }
		defaults.set(stored, forKey: Self.defaultsKey)
	}

	private static func validatedPrompt(name: String, prompt: String) -> AICustomPrompt? {
		let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedName.isEmpty, trimmedName.count <= maximumNameLength else {
			return nil
		}
		guard !trimmedPrompt.isEmpty, trimmedPrompt.count <= maximumPromptLength else {
			return nil
		}
		return AICustomPrompt(name: trimmedName, prompt: trimmedPrompt)
	}

	private static func prompt(from stored: [String: String]) -> AICustomPrompt? {
		guard let name = stored["name"], let prompt = stored["prompt"] else {
			return nil
		}
		return validatedPrompt(name: name, prompt: prompt)
	}

	/// Converts a legacy content-only prompt: the name is the first line of the content
	/// trimmed to 20 characters, and the content is kept as-is.
	private static func migratedPrompt(from legacy: String) -> AICustomPrompt? {
		let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			return nil
		}
		let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
		let nameText = firstLine.trimmingCharacters(in: .whitespaces).isEmpty ? trimmed : firstLine
		let name = String(nameText.prefix(maximumNameLength))
		return AICustomPrompt(name: name, prompt: legacy)
	}
}
