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
			addFullWidth(makeGroupHeader(group, showsAddButton: false))
			let row = NSStackView()
			row.orientation = .horizontal
			row.alignment = .centerY
			row.spacing = 6
			for task in groupedTasks[group] ?? [] {
				let button = makeButton(title: task.label, action: #selector(taskButtonClicked(_:)), tag: taskPrompts.count)
				taskPrompts.append(task.prompt)
				row.addArrangedSubview(button)
			}
			row.addArrangedSubview(NSView())
			addFullWidth(row)
		}

		addFullWidth(makeGroupHeader("自定义", showsAddButton: true))
		if customPrompts.isEmpty {
			let label = NSTextField(wrappingLabelWithString: "还没有自定义提示词。")
			label.font = .systemFont(ofSize: 11)
			label.textColor = .tertiaryLabelColor
			addFullWidth(label)
		} else {
			for (index, prompt) in customPrompts.enumerated() {
				let button = makeButton(title: prompt, action: #selector(customButtonClicked(_:)), tag: index)
				button.alignment = .left

				let menu = NSMenu()
				let deleteItem = NSMenuItem(title: "删除此提示词", action: #selector(deleteCustomPromptMenuItem(_:)), keyEquivalent: "")
				deleteItem.target = self
				deleteItem.tag = index
				menu.addItem(deleteItem)
				button.menu = menu

				addFullWidth(button)
			}
		}

		stack.layoutSubtreeIfNeeded()
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
		addButton.toolTip = "新增自定义提示词"

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
