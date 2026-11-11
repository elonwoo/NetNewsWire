//
//  AITaskTrayView.swift
//  NetNewsWire
//

import AppKit
import AI

/// The reading-task tray that floats above the composer in the AI chat pane.
/// Its contents come from `AIPrompts.readingTasks` plus the user's custom prompts.
final class AITaskTrayView: NSView {

	static let maximumHeight: CGFloat = 400

	var onSelectPrompt: ((String) -> Void)?
	var onAddCustomPrompt: (() -> Void)?
	var onEditCustomPrompt: ((Int) -> Void)?
	var onDeleteCustomPrompt: ((Int) -> Void)?
	var onClose: (() -> Void)?

	private static let horizontalInset: CGFloat = 10
	private static let verticalInset: CGFloat = 8
	private static let bottomInset: CGFloat = 9
	private static let groupLabelWidth: CGFloat = 42

	private let scrollView = NSScrollView()
	private let documentView = AIFlippedView()
	private let stack = NSStackView()
	private var taskPrompts: [String] = []
	private var customPrompts: [AICustomPrompt] = []

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setup()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyColors()
	}

	// The tray floats over the chat messages. Those selectable labels register
	// I-beam cursor rects, so the tray claims the whole panel as an arrow area.
	override func resetCursorRects() {
		addCursorRect(bounds, cursor: .arrow)
	}

	func reload(customPrompts: [AICustomPrompt]) {
		self.customPrompts = customPrompts
		rebuild()
	}

	/// Height that fits the current content, including the tray's insets.
	var contentHeight: CGFloat {
		stack.layoutSubtreeIfNeeded()
		let fittingHeight = stack.fittingSize.height
		let laidOutHeight = stack.arrangedSubviews.last?.frame.maxY ?? fittingHeight
		return max(fittingHeight, laidOutHeight) + Self.verticalInset + Self.bottomInset
	}
}

private extension AITaskTrayView {

	func setup() {
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.cornerRadius = 10
		layer?.borderWidth = 1
		layer?.masksToBounds = false
		layer?.shadowColor = NSColor.black.cgColor
		layer?.shadowOpacity = 0.18
		layer?.shadowRadius = 12
		layer?.shadowOffset = CGSize(width: 0, height: -3)
		applyColors()

		setAccessibilityElement(true)
		setAccessibilityRole(.group)
		setAccessibilityLabel("阅读任务托盘")

		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		addSubview(scrollView)

		// The insets are optional so a hidden tray can collapse to zero height
		// without breaking Auto Layout.
		let topConstraint = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset)
		let bottomConstraint = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset)
		topConstraint.priority = NSLayoutConstraint.Priority(999)
		bottomConstraint.priority = NSLayoutConstraint.Priority(999)

		NSLayoutConstraint.activate([
			topConstraint,
			scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
			scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
			bottomConstraint
		])

		documentView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.documentView = documentView

		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 0
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

	func applyColors() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
			layer?.borderColor = NSColor.separatorColor.cgColor
			layer?.shadowColor = NSColor.black.cgColor
		}
	}

	func rebuild() {
		for subview in stack.arrangedSubviews {
			stack.removeArrangedSubview(subview)
			subview.removeFromSuperview()
		}
		taskPrompts = []

		addHeader()
		addSeparator(spacingAfter: 4)

		var groupOrder: [String] = []
		var groupedTasks: [String: [ReadingTask]] = [:]
		for task in AIPrompts.readingTasks {
			if groupedTasks[task.group] == nil {
				groupOrder.append(task.group)
			}
			groupedTasks[task.group, default: []].append(task)
		}
		for group in groupOrder {
			addGroup(group, tasks: groupedTasks[group] ?? [])
		}

		addCustomSection()
		addHint()

		stack.layoutSubtreeIfNeeded()
	}

	func addHeader() {
		let title = makeLabel("阅读任务", size: 12, weight: .semibold, color: .labelColor)
		let count = makeLabel("\(AIPrompts.readingTasks.count + customPrompts.count)", size: 11, weight: .regular, color: .secondaryLabelColor)

		let closeButton = AIHoverButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭任务托盘") ?? NSImage(), target: self, action: #selector(closeClicked))
		closeButton.imagePosition = .imageOnly
		closeButton.title = ""
		closeButton.restFillAlpha = 0
		closeButton.hoverFillAlpha = 0.07
		closeButton.cornerRadius = 4
		closeButton.restTintColor = .tertiaryLabelColor
		closeButton.hoverTintColor = .tertiaryLabelColor
		closeButton.configureHover()
		closeButton.toolTip = "关闭任务托盘"
		closeButton.setAccessibilityLabel("关闭任务托盘")
		closeButton.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			closeButton.widthAnchor.constraint(equalToConstant: 20),
			closeButton.heightAnchor.constraint(equalToConstant: 20)
		])

		let spacer = NSView()
		let row = NSStackView(views: [title, count, spacer, closeButton])
		row.orientation = .horizontal
		row.alignment = .centerY
		row.spacing = 7
		addFullWidth(row, spacingAfter: 7)
	}

	func addGroup(_ group: String, tasks: [ReadingTask]) {
		let label = makeLabel(group, size: 11, weight: .regular, color: .secondaryLabelColor)
		label.translatesAutoresizingMaskIntoConstraints = false
		label.widthAnchor.constraint(equalToConstant: Self.groupLabelWidth).isActive = true

		let chips = NSStackView()
		chips.orientation = .horizontal
		chips.alignment = .centerY
		chips.spacing = 5
		for task in tasks {
			let button = makeChip(title: task.label, action: #selector(taskClicked(_:)), tag: taskPrompts.count)
			taskPrompts.append(task.prompt)
			chips.addArrangedSubview(button)
		}

		let spacer = NSView()
		let row = NSStackView(views: [label, chips, spacer])
		row.orientation = .horizontal
		row.alignment = .centerY
		row.spacing = 8
		addFullWidth(row, spacingAfter: 5)
	}

	func addCustomSection() {
		addSeparator(spacingAfter: 7)

		let label = makeLabel("自定义", size: 11, weight: .regular, color: .secondaryLabelColor)
		let count = makeLabel("\(customPrompts.count) / \(AICustomPromptStore.maximumCount)", size: 11, weight: .regular, color: .tertiaryLabelColor)

		let addButton = AIHoverButton(title: "+ 新增", target: self, action: #selector(addClicked))
		addButton.font = .systemFont(ofSize: 11)
		addButton.horizontalContentPadding = 7
		addButton.showsTitle = true
		addButton.restFillAlpha = 0
		addButton.hoverFillAlpha = 0.04
		addButton.cornerRadius = 5
		addButton.hasBorder = true
		addButton.restTintColor = .secondaryLabelColor
		addButton.hoverTintColor = .labelColor
		addButton.configureHover()
		addButton.toolTip = "新增自定义提示词"
		addButton.translatesAutoresizingMaskIntoConstraints = false
		addButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

		let spacer = NSView()
		let head = NSStackView(views: [label, count, spacer, addButton])
		head.orientation = .horizontal
		head.alignment = .centerY
		head.spacing = 7
		addFullWidth(head, spacingAfter: 5)

		if customPrompts.isEmpty {
			let empty = makeLabel("还没有自定义提示词", size: 11, weight: .regular, color: .tertiaryLabelColor)
			addFullWidth(empty, spacingAfter: 5)
			return
		}

		for (index, prompt) in customPrompts.enumerated() {
			addCustomRow(prompt, index: index)
		}
	}

	func addCustomRow(_ prompt: AICustomPrompt, index: Int) {
		let promptButton = AICustomPromptButton(name: prompt.name, prompt: prompt.prompt, target: self, action: #selector(customClicked(_:)))
		promptButton.tag = index
		promptButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
		promptButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let editImage = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "编辑此提示词")?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? NSImage()
		let editButton = makeRowActionButton(image: editImage, tint: .secondaryLabelColor, toolTip: "编辑此提示词", action: #selector(editClicked(_:)), tag: index)
		let deleteImage = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除此提示词")?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage()
		let deleteButton = makeRowActionButton(image: deleteImage, tint: .tertiaryLabelColor, toolTip: "删除此提示词", action: #selector(deleteClicked(_:)), tag: index)

		// Two-end alignment: the prompt column takes every point the icon
		// column does not, so long names truncate instead of pushing the icons.
		let row = NSView()
		row.translatesAutoresizingMaskIntoConstraints = false
		row.addSubview(promptButton)
		row.addSubview(editButton)
		row.addSubview(deleteButton)

		NSLayoutConstraint.activate([
			promptButton.leadingAnchor.constraint(equalTo: row.leadingAnchor),
			promptButton.topAnchor.constraint(equalTo: row.topAnchor),
			promptButton.bottomAnchor.constraint(equalTo: row.bottomAnchor),

			editButton.leadingAnchor.constraint(equalTo: promptButton.trailingAnchor, constant: 1),
			editButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

			deleteButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 1),
			deleteButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
			deleteButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
		])

		addFullWidth(row, spacingAfter: 2)
	}

	func makeRowActionButton(image: NSImage, tint: NSColor, toolTip: String, action: Selector, tag: Int) -> NSButton {
		let button = AIHoverButton(image: image, target: self, action: action)
		button.imagePosition = .imageOnly
		button.title = ""
		button.restFillAlpha = 0
		button.hoverFillAlpha = 0.07
		button.cornerRadius = 4
		button.restTintColor = tint
		button.hoverTintColor = tint
		button.configureHover()
		button.toolTip = toolTip
		button.setAccessibilityLabel(toolTip)
		button.tag = tag
		button.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 22),
			button.heightAnchor.constraint(equalToConstant: 22)
		])
		return button
	}

	func addHint() {
		addSeparator(spacingAfter: 7)
		let hint = makeLabel("选中后收起托盘并立即发送", size: 10.5, weight: .regular, color: .tertiaryLabelColor)
		addFullWidth(hint, spacingAfter: 0)
	}

	func addSeparator(spacingAfter: CGFloat) {
		let line = NSBox()
		line.boxType = .separator
		line.translatesAutoresizingMaskIntoConstraints = false
		line.heightAnchor.constraint(equalToConstant: 1).isActive = true
		addFullWidth(line, spacingAfter: spacingAfter)
	}

	func addFullWidth(_ view: NSView, spacingAfter: CGFloat) {
		stack.addArrangedSubview(view)
		view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		stack.setCustomSpacing(spacingAfter, after: view)
	}

	func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = .systemFont(ofSize: size, weight: weight)
		label.textColor = color
		label.lineBreakMode = .byTruncatingTail
		return label
	}

	func makeChip(title: String, action: Selector, tag: Int) -> NSButton {
		let button = AIHoverButton(title: title, target: self, action: action)
		button.font = .systemFont(ofSize: 11)
		button.horizontalContentPadding = 9
		button.showsTitle = true
		button.restFillAlpha = 0.04
		button.hoverFillAlpha = 0.07
		button.cornerRadius = 6
		button.hasBorder = true
		button.restTintColor = .labelColor
		button.hoverTintColor = .labelColor
		button.configureHover()
		button.tag = tag
		button.translatesAutoresizingMaskIntoConstraints = false
		button.heightAnchor.constraint(equalToConstant: 26).isActive = true
		button.setContentHuggingPriority(.required, for: .horizontal)
		button.setContentCompressionResistancePriority(.required, for: .horizontal)
		return button
	}

	@objc func taskClicked(_ sender: NSButton) {
		guard taskPrompts.indices.contains(sender.tag) else {
			return
		}
		onSelectPrompt?(taskPrompts[sender.tag])
	}

	@objc func customClicked(_ sender: NSButton) {
		guard customPrompts.indices.contains(sender.tag) else {
			return
		}
		onSelectPrompt?(customPrompts[sender.tag].prompt)
	}

	@objc func editClicked(_ sender: NSButton) {
		onEditCustomPrompt?(sender.tag)
	}

	@objc func deleteClicked(_ sender: NSButton) {
		onDeleteCustomPrompt?(sender.tag)
	}

	@objc func addClicked() {
		onAddCustomPrompt?()
	}

	@objc func closeClicked() {
		onClose?()
	}
}

/// A borderless tray button with the shared hover fill and tint treatment.
/// The alpha values match `AITaskButton`'s existing hover appearance.
private class AIHoverButton: NSButton {

	var restFillAlpha: CGFloat = 0
	var hoverFillAlpha: CGFloat = 0.07
	var restTintColor: NSColor = .tertiaryLabelColor
	var hoverTintColor: NSColor = .labelColor
	var cornerRadius: CGFloat = 4
	var hasBorder = false
	var showsTitle = false
	var horizontalContentPadding: CGFloat = 0 {
		didSet {
			invalidateIntrinsicContentSize()
		}
	}

	private var isHovered = false
	private var trackingArea: NSTrackingArea?

	override var intrinsicContentSize: NSSize {
		let size = super.intrinsicContentSize
		guard horizontalContentPadding > 0 else {
			return size
		}
		return NSSize(width: size.width + horizontalContentPadding * 2, height: size.height)
	}

	func configureHover() {
		isBordered = false
		wantsLayer = true
		layer?.cornerRadius = cornerRadius
		layer?.borderWidth = hasBorder ? 1 : 0
		updateAppearance()
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea {
			removeTrackingArea(trackingArea)
		}
		let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
		addTrackingArea(area)
		trackingArea = area
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		updateAppearance()
	}

	override func mouseEntered(with event: NSEvent) {
		isHovered = true
		updateAppearance()
	}

	override func mouseExited(with event: NSEvent) {
		isHovered = false
		updateAppearance()
	}

	private func updateAppearance() {
		let fillAlpha = isHovered ? hoverFillAlpha : restFillAlpha
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fillAlpha).cgColor
			if hasBorder {
				layer?.borderColor = NSColor.separatorColor.cgColor
			}
		}

		let tint = isHovered ? hoverTintColor : restTintColor
		contentTintColor = tint
		guard showsTitle else {
			return
		}
		attributedTitle = NSAttributedString(string: title, attributes: [
			.font: font ?? NSFont.systemFont(ofSize: 11),
			.foregroundColor: tint
		])
	}
}

/// A two-line custom-prompt row: the name on top, the prompt content preview below.
private final class AICustomPromptButton: AIHoverButton {

	init(name: String, prompt: String, target: AnyObject?, action: Selector?) {
		super.init(frame: .zero)
		title = ""
		self.target = target
		self.action = action

		restFillAlpha = 0
		hoverFillAlpha = 0.04
		cornerRadius = 5
		restTintColor = .labelColor
		hoverTintColor = .labelColor
		configureHover()

		let nameLabel = AICustomPromptLabel(labelWithString: name)
		nameLabel.font = .systemFont(ofSize: 13)
		nameLabel.textColor = .labelColor
		nameLabel.lineBreakMode = .byTruncatingTail
		nameLabel.maximumNumberOfLines = 1
		nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let bodyLabel = AICustomPromptLabel(labelWithString: prompt)
		bodyLabel.font = .systemFont(ofSize: 11)
		bodyLabel.textColor = .secondaryLabelColor
		bodyLabel.lineBreakMode = .byTruncatingTail
		bodyLabel.maximumNumberOfLines = 1
		bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let stack = NSStackView(views: [nameLabel, bodyLabel])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 1
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			nameLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
			bodyLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
			heightAnchor.constraint(equalToConstant: 36)
		])

		setAccessibilityLabel(name)
		setAccessibilityHelp(prompt)
		toolTip = prompt
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// The labels draw their own I-beam cursor rects. The row selects a prompt
	// instead of accepting text, so every part of it uses the arrow cursor.
	override func resetCursorRects() {
		addCursorRect(bounds, cursor: .arrow)
	}

	// The labels inside the button must not swallow clicks: the whole row selects the prompt.
	override func hitTest(_ point: NSPoint) -> NSView? {
		guard !isHidden, alphaValue > 0, let superview else {
			return nil
		}
		let localPoint = convert(point, from: superview)
		return bounds.contains(localPoint) ? self : nil
	}
}

/// A prompt-row label that never suggests text editing with an I-beam cursor.
private final class AICustomPromptLabel: NSTextField {

	override func resetCursorRects() {
		addCursorRect(bounds, cursor: .arrow)
	}
}

/// The composer button that opens and closes `AITaskTrayView`.
final class AITaskButton: NSButton {

	var count: Int = 0 {
		didSet {
			countLabel.stringValue = "\(count)"
			setAccessibilityValue("\(count) 项")
		}
	}

	var isOpen: Bool = false {
		didSet {
			chevronView.image = NSImage(systemSymbolName: isOpen ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
			updateAppearance()
		}
	}

	override var isEnabled: Bool {
		didSet {
			updateAppearance()
		}
	}

	private let iconView = NSImageView()
	private let titleLabel = NSTextField(labelWithString: "任务")
	private let countLabel = NSTextField(labelWithString: "")
	private let chevronView = NSImageView()
	private let contentStack = NSStackView()
	private var isHovered = false
	private var trackingArea: NSTrackingArea?

	init() {
		super.init(frame: .zero)
		setup()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		updateAppearance()
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea {
			removeTrackingArea(trackingArea)
		}
		let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
		addTrackingArea(area)
		trackingArea = area
	}

	override func mouseEntered(with event: NSEvent) {
		isHovered = true
		updateAppearance()
	}

	override func mouseExited(with event: NSEvent) {
		isHovered = false
		updateAppearance()
	}
}

private extension AITaskButton {

	func setup() {
		isBordered = false
		title = ""
		wantsLayer = true
		layer?.cornerRadius = 6
		layer?.borderWidth = 1
		translatesAutoresizingMaskIntoConstraints = false
		heightAnchor.constraint(equalToConstant: 24).isActive = true

		setAccessibilityLabel("阅读任务")
		setAccessibilityHelp("展开或收起阅读任务托盘")
		setAccessibilityValue("12 项")
		toolTip = "阅读任务"

		iconView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
		iconView.contentTintColor = .secondaryLabelColor
		iconView.translatesAutoresizingMaskIntoConstraints = false

		titleLabel.font = .systemFont(ofSize: 11)
		titleLabel.textColor = .labelColor

		countLabel.font = .systemFont(ofSize: 11)
		countLabel.textColor = .secondaryLabelColor

		chevronView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
		chevronView.contentTintColor = .tertiaryLabelColor
		chevronView.translatesAutoresizingMaskIntoConstraints = false

		contentStack.orientation = .horizontal
		contentStack.alignment = .centerY
		contentStack.spacing = 5
		contentStack.translatesAutoresizingMaskIntoConstraints = false
		for content in [iconView, titleLabel, countLabel, chevronView] {
			contentStack.addArrangedSubview(content)
		}
		addSubview(contentStack)

		NSLayoutConstraint.activate([
			contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
			contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
			contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
		])

		updateAppearance()
	}

	func updateAppearance() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			let fillAlpha: CGFloat = isOpen ? 0.10 : (isHovered ? 0.07 : 0.04)
			layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fillAlpha).cgColor
			layer?.borderColor = NSColor.separatorColor.cgColor
		}
		alphaValue = isEnabled ? 1 : 0.5
		titleLabel.textColor = isEnabled ? .labelColor : .secondaryLabelColor
		countLabel.textColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
	}
}
