//
//  AIChatViewController.swift
//  NetNewsWire
//

import AppKit
import AI
import Articles

/// The fourth pane: per-article chat with reading tasks, custom prompts and quoted context.
@MainActor
final class AIChatViewController: NSViewController {

	/// Fetches the text selected in the reading area.
	var selectedTextProvider: ((@escaping (String?) -> Void) -> Void)?

	/// Called when Escape is pressed in the input field. The input keeps its text.
	var onEscape: (() -> Void)?

	var article: Article? {
		didSet {
			guard article?.articleID != oldValue?.articleID else {
				return
			}
			articleTitleLabel.stringValue = article?.title ?? "未选择文章"
			resetConversation()
			loadMessages()
			updateInputState()
		}
	}

	private let headerTitleLabel = NSTextField(labelWithString: "AI 对话")
	private let articleTitleLabel = NSTextField(labelWithString: "未选择文章")
	private let quoteButton = NSButton()
	private let messagesScrollView = NSScrollView()
	private let messagesDocumentView = AIFlippedView()
	private let messagesStack = NSStackView()
	private let taskListView = AITaskListView()
	private let errorLabel = NSTextField(wrappingLabelWithString: "")
	private let statusLabel = NSTextField(labelWithString: "")
	private let inputScrollView = NSScrollView()
	private let inputTextView = NSTextView()
	private let sendButton = NSButton()
	private let customPromptStore = AICustomPromptStore()

	private var storedMessages: [ChatMessage] = []
	private var pendingUserMessage: ChatMessage?
	private var isSending = false
	private var loadToken = UUID()

	override func loadView() {
		let rootView = NSView()
		view = rootView

		let headerRow = makeHeaderRow()
		let bottomStack = makeBottomStack()
		makeMessagesView()

		rootView.addSubview(headerRow)
		rootView.addSubview(messagesScrollView)
		rootView.addSubview(bottomStack)

		NSLayoutConstraint.activate([
			headerRow.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: 10),
			headerRow.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
			headerRow.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),

			messagesScrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 8),
			messagesScrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
			messagesScrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
			messagesScrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),

			bottomStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 10),
			bottomStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -10),
			bottomStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -10)
		])

		taskListView.reload(customPrompts: customPromptStore.prompts)
		updateInputState()
		rebuildMessages()
	}

	func focusInput() {
		view.window?.makeFirstResponder(inputTextView)
	}
}

// MARK: - View construction

private extension AIChatViewController {

	func makeHeaderRow() -> NSView {
		headerTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
		articleTitleLabel.font = .systemFont(ofSize: 11)
		articleTitleLabel.textColor = .secondaryLabelColor
		articleTitleLabel.lineBreakMode = .byTruncatingTail
		articleTitleLabel.maximumNumberOfLines = 1

		let titleStack = NSStackView(views: [headerTitleLabel, articleTitleLabel])
		titleStack.orientation = .vertical
		titleStack.alignment = .leading
		titleStack.spacing = 2

		quoteButton.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "引用选中文本")
		quoteButton.bezelStyle = .texturedRounded
		quoteButton.isBordered = false
		quoteButton.imagePosition = .imageOnly
		quoteButton.toolTip = "引用选中文本"
		quoteButton.target = self
		quoteButton.action = #selector(quoteSelection)

		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let row = NSStackView(views: [titleStack, spacer, quoteButton])
		row.orientation = .horizontal
		row.alignment = .centerY
		row.spacing = 8
		row.translatesAutoresizingMaskIntoConstraints = false
		return row
	}

	func makeMessagesView() {
		messagesScrollView.translatesAutoresizingMaskIntoConstraints = false
		messagesScrollView.hasVerticalScroller = true
		messagesScrollView.autohidesScrollers = true
		messagesScrollView.drawsBackground = false
		messagesScrollView.borderType = .noBorder

		messagesDocumentView.translatesAutoresizingMaskIntoConstraints = false
		messagesScrollView.documentView = messagesDocumentView

		messagesStack.translatesAutoresizingMaskIntoConstraints = false
		messagesStack.orientation = .vertical
		messagesStack.alignment = .leading
		messagesStack.spacing = 8
		messagesStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
		messagesDocumentView.addSubview(messagesStack)

		NSLayoutConstraint.activate([
			messagesDocumentView.topAnchor.constraint(equalTo: messagesScrollView.contentView.topAnchor),
			messagesDocumentView.leadingAnchor.constraint(equalTo: messagesScrollView.contentView.leadingAnchor),
			messagesDocumentView.trailingAnchor.constraint(equalTo: messagesScrollView.contentView.trailingAnchor),
			messagesDocumentView.widthAnchor.constraint(equalTo: messagesScrollView.contentView.widthAnchor),
			messagesStack.topAnchor.constraint(equalTo: messagesDocumentView.topAnchor),
			messagesStack.leadingAnchor.constraint(equalTo: messagesDocumentView.leadingAnchor),
			messagesStack.trailingAnchor.constraint(equalTo: messagesDocumentView.trailingAnchor),
			messagesStack.bottomAnchor.constraint(equalTo: messagesDocumentView.bottomAnchor)
		])
	}

	func makeBottomStack() -> NSStackView {
		taskListView.onSelectTask = { [weak self] prompt in
			self?.send(prompt: prompt)
		}
		taskListView.onAddCustomPrompt = { [weak self] in
			self?.promptForCustomPrompt()
		}
		taskListView.onDeleteCustomPrompt = { [weak self] index in
			self?.deleteCustomPrompt(at: index)
		}
		taskListView.translatesAutoresizingMaskIntoConstraints = false
		taskListView.heightAnchor.constraint(equalToConstant: 300).isActive = true

		errorLabel.font = .systemFont(ofSize: 11)
		errorLabel.textColor = .systemRed
		errorLabel.isHidden = true
		errorLabel.maximumNumberOfLines = 3

		statusLabel.font = .systemFont(ofSize: 11)
		statusLabel.textColor = .secondaryLabelColor
		statusLabel.isHidden = true

		inputScrollView.translatesAutoresizingMaskIntoConstraints = false
		inputScrollView.hasVerticalScroller = true
		inputScrollView.autohidesScrollers = true
		inputScrollView.borderType = .bezelBorder
		inputScrollView.drawsBackground = true

		inputTextView.minSize = NSSize(width: 0, height: 0)
		inputTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		inputTextView.isVerticallyResizable = true
		inputTextView.isHorizontallyResizable = false
		inputTextView.autoresizingMask = [.width]
		inputTextView.isRichText = false
		inputTextView.isAutomaticQuoteSubstitutionEnabled = false
		inputTextView.isAutomaticDashSubstitutionEnabled = false
		inputTextView.isAutomaticTextReplacementEnabled = false
		inputTextView.font = .systemFont(ofSize: 12)
		inputTextView.textContainerInset = NSSize(width: 4, height: 5)
		inputTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
		inputTextView.textContainer?.widthTracksTextView = true
		inputTextView.delegate = self
		inputScrollView.documentView = inputTextView
		inputScrollView.heightAnchor.constraint(equalToConstant: 62).isActive = true

		sendButton.title = "发送"
		sendButton.bezelStyle = .rounded
		sendButton.target = self
		sendButton.action = #selector(sendFromInput)
		sendButton.setContentHuggingPriority(.required, for: .horizontal)

		let inputRow = NSStackView(views: [inputScrollView, sendButton])
		inputRow.orientation = .horizontal
		inputRow.alignment = .centerY
		inputRow.spacing = 8
		inputRow.distribution = .fill

		let stack = NSStackView(views: [taskListView, errorLabel, statusLabel, inputRow])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false

		for arrangedView in [taskListView, errorLabel, statusLabel, inputRow] {
			arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		}

		return stack
	}
}

// MARK: - Conversation

private extension AIChatViewController {

	func resetConversation() {
		storedMessages = []
		pendingUserMessage = nil
		isSending = false
		errorLabel.isHidden = true
		statusLabel.isHidden = true
		rebuildMessages()
	}

	func loadMessages() {
		guard let articleID = article?.articleID else {
			storedMessages = []
			rebuildMessages()
			return
		}

		let token = UUID()
		loadToken = token
		Task { @MainActor in
			do {
				let messages = try await AIEnvironment.shared.store.chatMessages(for: articleID)
				guard self.loadToken == token, self.article?.articleID == articleID else {
					return
				}
				self.storedMessages = messages
				self.rebuildMessages()
			} catch {
				guard self.loadToken == token else {
					return
				}
				self.showError("读取对话失败：\(error.localizedDescription)")
			}
		}
	}

	func send(prompt: String) {
		guard !isSending else {
			return
		}
		guard let article else {
			showError("请先选择一篇文章。")
			return
		}

		let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedPrompt.isEmpty else {
			return
		}

		errorLabel.isHidden = true
		pendingUserMessage = ChatMessage(
			id: UUID().uuidString,
			articleID: article.articleID,
			role: .user,
			content: trimmedPrompt,
			model: nil,
			createdAt: Date()
		)
		isSending = true
		updateSendingState()
		rebuildMessages()
		inputTextView.string = ""

		let history = storedMessages
		let articleID = article.articleID
		let aiArticle = AIArticle(article: article)

		Task { @MainActor in
			do {
				_ = try await AIEnvironment.shared.engine.chat(article: aiArticle, history: history, userMessage: trimmedPrompt)
				guard self.article?.articleID == articleID else {
					return
				}
				self.pendingUserMessage = nil
				self.isSending = false
				self.updateSendingState()
				await self.reloadMessagesFromStore(articleID: articleID)
			} catch {
				guard self.article?.articleID == articleID else {
					return
				}
				self.isSending = false
				self.updateSendingState()
				self.showError("发送失败：\(error.localizedDescription)")
			}
		}
	}

	func reloadMessagesFromStore(articleID: String) async {
		do {
			let messages = try await AIEnvironment.shared.store.chatMessages(for: articleID)
			guard article?.articleID == articleID else {
				return
			}
			storedMessages = messages
			rebuildMessages()
		} catch {
			guard article?.articleID == articleID else {
				return
			}
			showError("读取对话失败：\(error.localizedDescription)")
		}
	}

	func rebuildMessages() {
		for subview in messagesStack.arrangedSubviews {
			messagesStack.removeArrangedSubview(subview)
			subview.removeFromSuperview()
		}

		if storedMessages.isEmpty, pendingUserMessage == nil {
			let hint = NSTextField(wrappingLabelWithString: "选择下方的阅读任务，或输入问题开始对话。")
			hint.font = .systemFont(ofSize: 12)
			hint.textColor = .secondaryLabelColor
			hint.alignment = .center
			addMessageRow(hint)
		} else {
			for message in storedMessages {
				addMessageRow(AIMessageRowView(message: message))
			}
			if let pendingUserMessage {
				addMessageRow(AIMessageRowView(message: pendingUserMessage))
			}
		}

		messagesDocumentView.layoutSubtreeIfNeeded()
		scrollToBottom()
	}

	func addMessageRow(_ row: NSView) {
		messagesStack.addArrangedSubview(row)
		row.widthAnchor.constraint(equalTo: messagesStack.widthAnchor, constant: -16).isActive = true
	}

	func scrollToBottom() {
		Task { @MainActor in
			self.messagesDocumentView.layoutSubtreeIfNeeded()
			let documentHeight = self.messagesDocumentView.bounds.height
			let clipHeight = self.messagesScrollView.contentView.bounds.height
			let y = max(0, documentHeight - clipHeight)
			self.messagesScrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
			self.messagesScrollView.reflectScrolledClipView(self.messagesScrollView.contentView)
		}
	}

	func updateSendingState() {
		sendButton.isEnabled = !isSending && article != nil
		statusLabel.stringValue = isSending ? "正在思考…" : ""
		statusLabel.isHidden = !isSending
	}

	func updateInputState() {
		let hasArticle = article != nil
		inputTextView.isEditable = hasArticle
		quoteButton.isEnabled = hasArticle
		updateSendingState()
	}

	func showError(_ message: String) {
		errorLabel.stringValue = message
		errorLabel.isHidden = false
	}
}

// MARK: - Actions

private extension AIChatViewController {

	@objc func sendFromInput() {
		send(prompt: inputTextView.string)
	}

	@objc func quoteSelection() {
		guard let selectedTextProvider else {
			showError("当前无法读取选中文本。")
			return
		}
		selectedTextProvider { [weak self] text in
			Task { @MainActor in
				guard let self else {
					return
				}
				guard let text, !text.isEmpty else {
					self.showError("阅读区没有选中文本。")
					return
				}
				self.insertQuote(text)
			}
		}
	}

	func insertQuote(_ text: String) {
		let quoted = text
			.split(separator: "\n", omittingEmptySubsequences: false)
			.map { "> \($0)" }
			.joined(separator: "\n")
		let existing = inputTextView.string
		let prefix = existing.isEmpty ? "" : existing + "\n\n"
		inputTextView.string = prefix + quoted + "\n\n"
		let end = inputTextView.string.utf16.count
		inputTextView.setSelectedRange(NSRange(location: end, length: 0))
		view.window?.makeFirstResponder(inputTextView)
	}

	func promptForCustomPrompt() {
		let alert = NSAlert()
		alert.messageText = "新增自定义提示词"
		alert.informativeText = "保存后出现在「自定义」分组，最多 \(AICustomPromptStore.maximumCount) 条。"
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
		field.placeholderString = "输入提示词"
		alert.accessoryView = field
		alert.addButton(withTitle: "保存")
		alert.addButton(withTitle: "取消")

		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}
		addCustomPrompt(field.stringValue)
	}

	func addCustomPrompt(_ text: String) {
		guard customPromptStore.add(text) else {
			let message = customPromptStore.prompts.count >= AICustomPromptStore.maximumCount
				? "自定义提示词已达上限（\(AICustomPromptStore.maximumCount) 条）。"
				: "提示词为空或已存在。"
			showError(message)
			return
		}
		errorLabel.isHidden = true
		taskListView.reload(customPrompts: customPromptStore.prompts)
	}

	func deleteCustomPrompt(at index: Int) {
		customPromptStore.remove(at: index)
		taskListView.reload(customPrompts: customPromptStore.prompts)
	}
}

// MARK: - NSTextViewDelegate

extension AIChatViewController: NSTextViewDelegate {

	func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
		if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
			onEscape?()
			return true
		}
		guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
			return false
		}
		if NSEvent.modifierFlags.contains(.shift) {
			return false
		}
		sendFromInput()
		return true
	}
}
