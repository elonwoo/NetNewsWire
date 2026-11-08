//
//  AITaskListView.swift
//  NetNewsWire
//

import AppKit
import AI

/// The reading tasks from `AIPrompts.readingTasks`, grouped as they are defined,
/// plus the user's custom prompts.
final class AITaskListView: NSView {

	var onSelectTask: ((String) -> Void)?
	var onAddCustomPrompt: (() -> Void)?
	var onDeleteCustomPrompt: ((Int) -> Void)?

	private let scrollView = NSScrollView()
	private let documentView = AIFlippedView()
	private let stack = NSStackView()
	private var taskPrompts: [String] = []
	private var customPrompts: [String] = []

	/// Maps the Chinese group and label names defined in `AIPrompts.readingTasks`
	/// to their English string-table keys. The prompts themselves stay unchanged
	/// because they are sent to the model.
	private static let taskDisplayKeys: [String: String] = [
		"理解": "Understanding",
		"核查": "Verification",
		"反驳": "Counterargument",
		"行动": "Action",
		"写作": "Writing",
		"延伸": "Further Reading",
		"总结要点": "Summarize Key Points",
		"结构拆解": "Break Down the Argument",
		"事实清单": "Fact Checklist",
		"待验证点": "Points to Verify",
		"反方观点": "Opposing View",
		"前提测试": "Test the Premises",
		"行动建议": "Action Suggestions",
		"产品机会": "Product Opportunities",
		"分享文案": "Share Copy",
		"选题角度": "Content Angles",
		"延伸阅读": "Further Reading Suggestions",
		"关联概念": "Related Concepts"
	]

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setup()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func reload(customPrompts: [String]) {
		self.customPrompts = customPrompts
		rebuild()
	}
}

private extension AITaskListView {

	func setup() {
		translatesAutoresizingMaskIntoConstraints = false

		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		addSubview(scrollView)
		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		documentView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.documentView = documentView

		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 4
		stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
		documentView.addSubview(stack)

		NSLayoutConstraint.activate([
			documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
			documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
			documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
			documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
			stack.topAnchor.constraint(equalTo: documentView.topAnchor),
			stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
		])
	}

	func rebuild() {
		for subview in stack.arrangedSubviews {
			stack.removeArrangedSubview(subview)
			subview.removeFromSuperview()
		}
		taskPrompts = []

		var groupOrder: [String] = []
		var groupedTasks: [String: [ReadingTask]] = [:]
		for task in AIPrompts.readingTasks {
			if groupedTasks[task.group] == nil {
				groupOrder.append(task.group)
			}
			groupedTasks[task.group, default: []].append(task)
		}

		for group in groupOrder {
			addFullWidth(makeGroupHeader(displayName(for: group), showsAddButton: false))
			let row = NSStackView()
			row.orientation = .horizontal
			row.alignment = .centerY
			row.spacing = 6
			for task in groupedTasks[group] ?? [] {
				let button = makeButton(title: displayName(for: task.label), action: #selector(taskButtonClicked(_:)), tag: taskPrompts.count)
				taskPrompts.append(task.prompt)
				row.addArrangedSubview(button)
			}
			row.addArrangedSubview(NSView())
			addFullWidth(row)
		}

		addFullWidth(makeGroupHeader(AILocalization.string("Custom"), showsAddButton: true))
		if customPrompts.isEmpty {
			let label = NSTextField(wrappingLabelWithString: AILocalization.string("No custom prompts yet."))
			label.font = .systemFont(ofSize: 11)
			label.textColor = .tertiaryLabelColor
			addFullWidth(label)
		} else {
			for (index, prompt) in customPrompts.enumerated() {
				let button = makeButton(title: prompt, action: #selector(customButtonClicked(_:)), tag: index)
				button.alignment = .left

				let menu = NSMenu()
				let deleteItem = NSMenuItem(title: AILocalization.string("Delete This Prompt"), action: #selector(deleteCustomPromptMenuItem(_:)), keyEquivalent: "")
				deleteItem.target = self
				deleteItem.tag = index
				menu.addItem(deleteItem)
				button.menu = menu

				addFullWidth(button)
			}
		}

		stack.layoutSubtreeIfNeeded()
	}

	func displayName(for name: String) -> String {
		guard let key = Self.taskDisplayKeys[name] else {
			return name
		}
		return AILocalization.string(key)
	}

	func addFullWidth(_ view: NSView) {
		stack.addArrangedSubview(view)
		view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
	}

	func makeGroupHeader(_ title: String, showsAddButton: Bool) -> NSView {
		let label = NSTextField(labelWithString: title)
		label.font = .systemFont(ofSize: 11, weight: .semibold)
		label.textColor = .secondaryLabelColor

		guard showsAddButton else {
			return label
		}

		let addButton = NSButton(title: "+", target: self, action: #selector(addCustomPromptClicked))
		addButton.bezelStyle = .inline
		addButton.isBordered = false
		addButton.font = .systemFont(ofSize: 13, weight: .semibold)
		addButton.toolTip = AILocalization.string("Add Custom Prompt")

		let row = NSStackView(views: [label, NSView(), addButton])
		row.orientation = .horizontal
		row.alignment = .centerY
		row.spacing = 4
		return row
	}

	func makeButton(title: String, action: Selector, tag: Int) -> NSButton {
		let button = NSButton(title: title, target: self, action: action)
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = .systemFont(ofSize: 11)
		button.tag = tag
		button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		return button
	}

	@objc func taskButtonClicked(_ sender: NSButton) {
		guard taskPrompts.indices.contains(sender.tag) else {
			return
		}
		onSelectTask?(taskPrompts[sender.tag])
	}

	@objc func customButtonClicked(_ sender: NSButton) {
		guard customPrompts.indices.contains(sender.tag) else {
			return
		}
		onSelectTask?(customPrompts[sender.tag])
	}

	@objc func deleteCustomPromptMenuItem(_ sender: NSMenuItem) {
		onDeleteCustomPrompt?(sender.tag)
	}

	@objc func addCustomPromptClicked() {
		onAddCustomPrompt?()
	}
}
