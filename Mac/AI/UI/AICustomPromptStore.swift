//
//  AICustomPromptStore.swift
//  NetNewsWire
//

import Foundation

/// Keeps user-written chat prompts in UserDefaults, capped at 24 entries.
@MainActor
final class AICustomPromptStore {

	static let maximumCount = 24

	private static let defaultsKey = "aiCustomPrompts"

	private let defaults: UserDefaults
	private(set) var prompts: [String] = []

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		reload()
	}

	func reload() {
		let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
		prompts = Array(stored.prefix(Self.maximumCount))
	}

	/// Adds a prompt. Returns false when it is empty, a duplicate, or the list is full.
	@discardableResult
	func add(_ prompt: String) -> Bool {
		let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, prompts.count < Self.maximumCount, !prompts.contains(trimmed) else {
			return false
		}
		prompts.append(trimmed)
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
		defaults.set(prompts, forKey: Self.defaultsKey)
	}
}
