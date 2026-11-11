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
			streamTask?.cancel()
			streamTask = nil
			closeTray()
			pendingQuote = nil
			updateQuoteChip()
			articleTitleLabel.stringValue = article?.title ?? "未选择文章"
			resetConversation()
			loadMessages()
			updateInputState()
		}
	}

	deinit {
		streamTask?.cancel()
		if let localMouseMonitor {
			NSEvent.removeMonitor(localMouseMonitor)
		}
		if let globalMouseMonitor {
			NSEvent.removeMonitor(globalMouseMonitor)
		}
		if let escapeKeyMonitor {
			NSEvent.removeMonitor(escapeKeyMonitor)
		}
	}

	private let headerTitleLabel = NSTextField(labelWithString: "AI 对话")
	private let articleTitleLabel = NSTextField(labelWithString: "未选择文章")
	private let quoteButton = NSButton()
	private let messagesScrollView = NSScrollView()
	private let messagesDocumentView = AIFlippedView()
	private let messagesStack = NSStackView()
	private let taskButton = AITaskButton()
	private let taskTray = AITaskTrayView()
	private let errorLabel = NSTextField(wrappingLabelWithString: "")
	private let quoteChipView = AIQuoteChipView()
	private let quoteLabel = NSTextField(wrappingLabelWithString: "")
	private let inputBox = AIComposerBoxView()
	private let inputScrollView = NSScrollView()
	private let inputTextView = NSTextView()
	private let sendButton = NSButton()
	private let customPromptStore = AICustomPromptStore()

	private var storedMessages: [ChatMessage] = []
	private var pendingUserMessage: ChatMessage?
	private var pendingAssistantText: String?
	private var streamingRow: AIMessageRowView?
	private var streamTask: Task<Void, Never>?
	private var isSending = false
	private var receivedDelta = false
	private var lastStreamRenderTime = Date.distantPast
	private var loadToken = UUID()
	private var pendingQuote: String?
	private var isTrayOpen = false
	private var trayHeightConstraint: NSLayoutConstraint?
	nonisolated(unsafe) private var localMouseMonitor: Any?
	nonisolated(unsafe) private var globalMouseMonitor: Any?
	nonisolated(unsafe) private var escapeKeyMonitor: Any?

	private static let thinkingPlaceholder = "正在生成回复…"
	private static let streamingRenderInterval: TimeInterval = 0.1
	private static let streamFollowThreshold: CGFloat = 60

	override func loadView() {
		let rootView = NSView()
		view = rootView

		let headerRow = makeHeaderRow()
		let bottomStack = makeBottomStack()
		makeMessagesView()

		rootView.addSubview(headerRow)
		rootView.addSubview(messagesScrollView)
		rootView.addSubview(bottomStack)
		rootView.addSubview(taskTray)

		taskTray.isHidden = true
		let trayHeightConstraint = taskTray.heightAnchor.constraint(equalToConstant: 0)
		self.trayHeightConstraint = trayHeightConstraint

		NSLayoutConstraint.activate([
			taskTray.leadingAnchor.constraint(equalTo: bottomStack.leadingAnchor),
			taskTray.trailingAnchor.constraint(equalTo: bottomStack.trailingAnchor),
			taskTray.bottomAnchor.constraint(equalTo: taskButton.topAnchor, constant: -9),
			taskTray.topAnchor.constraint(greaterThanOrEqualTo: messagesScrollView.topAnchor, constant: 4),
			trayHeightConstraint
		])
		taskTray.onSelectPrompt = { [weak self] prompt in
			guard let self, !self.isSending else {
				return
			}
			self.closeTray()
			self.send(prompt: prompt)
		}
		taskTray.onAddCustomPrompt = { [weak self] in
			self?.promptForNewCustomPrompt()
		}
		taskTray.onEditCustomPrompt = { [weak self] index in
			self?.promptForEditingCustomPrompt(at: index)
		}
		taskTray.onDeleteCustomPrompt = { [weak self] index in
			self?.deleteCustomPrompt(at: index)
		}
		taskTray.onClose = { [weak self] in
			self?.closeTray()
		}

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

		updateTaskButtonCount()
		updateInputState()
		rebuildMessages()
	}

	override func viewDidLayout() {
		super.viewDidLayout()
		updateTrayHeight()
		updateQuoteLabelWidth()
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
		taskButton.target = self
		taskButton.action = #selector(toggleTaskTray)

		errorLabel.font = .systemFont(ofSize: 11)
		errorLabel.textColor = .systemRed
		errorLabel.isHidden = true
		errorLabel.maximumNumberOfLines = 3

		makeQuoteChip()
		makeInputBox()

		sendButton.title = "发送"
		sendButton.bezelStyle = .rounded
		sendButton.target = self
		sendButton.action = #selector(sendFromInput)
		sendButton.setContentHuggingPriority(.required, for: .horizontal)

		let inputRow = NSStackView(views: [inputBox, sendButton])
		inputRow.orientation = .horizontal
		inputRow.alignment = .bottom
		inputRow.spacing = 8
		inputRow.distribution = .fill

		let spacer = NSView()
		let taskRow = NSStackView(views: [taskButton, spacer])
		taskRow.orientation = .horizontal
		taskRow.alignment = .centerY
		taskRow.spacing = 8

		let stack = NSStackView(views: [errorLabel, taskRow, inputRow])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false

		for arrangedView in [errorLabel, taskRow, inputRow] {
			arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		}

		return stack
	}

	func makeQuoteChip() {
		quoteChipView.translatesAutoresizingMaskIntoConstraints = false
		quoteChipView.isHidden = true

		let tag = NSTextField(labelWithString: "引用")
		tag.font = .systemFont(ofSize: 10, weight: .semibold)
		tag.textColor = .tertiaryLabelColor
		tag.setContentHuggingPriority(.required, for: .horizontal)
		tag.setContentCompressionResistancePriority(.required, for: .horizontal)

		quoteLabel.font = .systemFont(ofSize: 11)
		quoteLabel.textColor = .secondaryLabelColor
		quoteLabel.maximumNumberOfLines = 2
		quoteLabel.lineBreakMode = .byWordWrapping
		quoteLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		quoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let removeButton = NSButton(title: "×", target: self, action: #selector(removeQuote))
		removeButton.isBordered = false
		removeButton.font = .systemFont(ofSize: 13)
		removeButton.contentTintColor = .tertiaryLabelColor
		removeButton.toolTip = "移除引用"
		removeButton.setAccessibilityLabel("移除引用")
		removeButton.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			removeButton.widthAnchor.constraint(equalToConstant: 20),
			removeButton.heightAnchor.constraint(equalToConstant: 20)
		])

		let chipStack = NSStackView(views: [tag, quoteLabel, removeButton])
		chipStack.orientation = .horizontal
		chipStack.alignment = .top
		chipStack.spacing = 7
		chipStack.translatesAutoresizingMaskIntoConstraints = false
		quoteChipView.addSubview(chipStack)

		NSLayoutConstraint.activate([
			chipStack.topAnchor.constraint(equalTo: quoteChipView.topAnchor, constant: 5),
			chipStack.leadingAnchor.constraint(equalTo: quoteChipView.leadingAnchor, constant: 7),
			chipStack.trailingAnchor.constraint(equalTo: quoteChipView.trailingAnchor, constant: -4),
			chipStack.bottomAnchor.constraint(equalTo: quoteChipView.bottomAnchor, constant: -5)
		])
	}

	func makeInputBox() {
		inputBox.translatesAutoresizingMaskIntoConstraints = false

		inputScrollView.translatesAutoresizingMaskIntoConstraints = false
		inputScrollView.hasVerticalScroller = true
		inputScrollView.autohidesScrollers = true
		inputScrollView.borderType = .noBorder
		inputScrollView.drawsBackground = false

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
		inputTextView.textColor = .labelColor
		inputTextView.drawsBackground = false
		inputTextView.textContainerInset = NSSize(width: 4, height: 5)
		inputTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
		inputTextView.textContainer?.widthTracksTextView = true
		inputTextView.delegate = self
		inputScrollView.documentView = inputTextView
		inputScrollView.heightAnchor.constraint(equalToConstant: 58).isActive = true

		let inputStack = NSStackView(views: [quoteChipView, inputScrollView])
		inputStack.orientation = .vertical
		inputStack.alignment = .leading
		inputStack.spacing = 6
		inputStack.translatesAutoresizingMaskIntoConstraints = false
		inputBox.addSubview(inputStack)

		NSLayoutConstraint.activate([
			inputStack.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 6),
			inputStack.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 6),
			inputStack.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -6),
			inputStack.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: -6),
			quoteChipView.widthAnchor.constraint(equalTo: inputStack.widthAnchor),
			inputScrollView.widthAnchor.constraint(equalTo: inputStack.widthAnchor)
		])
	}
}

// MARK: - Conversation

private extension AIChatViewController {

	func resetConversation() {
		streamTask?.cancel()
		streamTask = nil
		storedMessages = []
		pendingUserMessage = nil
		pendingAssistantText = nil
		streamingRow = nil
		isSending = false
		receivedDelta = false
		errorLabel.isHidden = true
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
		let quote = pendingQuote?.trimmingCharacters(in: .whitespacesAndNewlines)
		var promptParts: [String] = []
		if let quote, !quote.isEmpty {
			promptParts.append(makeQuoteBlock(quote))
		}
		if !trimmedPrompt.isEmpty {
			promptParts.append(trimmedPrompt)
		}
		let composedPrompt = promptParts.joined(separator: "\n\n")
		guard !composedPrompt.isEmpty else {
			return
		}

		errorLabel.isHidden = true
		pendingUserMessage = ChatMessage(
			id: UUID().uuidString,
			articleID: article.articleID,
			role: .user,
			content: composedPrompt,
			model: nil,
			createdAt: Date()
		)
		pendingAssistantText = Self.thinkingPlaceholder
		receivedDelta = false
		lastStreamRenderTime = .distantPast
		isSending = true
		closeTray()
		pendingQuote = nil
		updateQuoteChip()
		updateSendingState()
		rebuildMessages()
		inputTextView.string = ""

		let restoreQuote = quote
		let history = storedMessages
		let articleID = article.articleID
		let aiArticle = AIArticle(article: article)

		streamTask?.cancel()
		streamTask = Task { @MainActor in
			do {
				let stream = AIEnvironment.shared.engine.chatStream(article: aiArticle, history: history, userMessage: composedPrompt)
				for try await event in stream {
					guard self.article?.articleID == articleID else {
						return
					}
					switch event {
					case .delta(let delta):
						if !self.receivedDelta {
							self.receivedDelta = true
							self.pendingAssistantText = ""
							self.updateSendingState()
						}
						self.pendingAssistantText = (self.pendingAssistantText ?? "") + delta
						let now = Date()
						if now.timeIntervalSince(self.lastStreamRenderTime) >= Self.streamingRenderInterval {
							self.lastStreamRenderTime = now
							self.renderStreamingRow()
						}
					case .finished(let message):
						await self.finishStreaming(articleID: articleID, message: message, restoreQuote: restoreQuote)
						return
					}
				}
				self.handleStreamFailure(AIClientError.invalidResponse, articleID: articleID, restoreQuote: restoreQuote)
			} catch {
				self.handleStreamFailure(error, articleID: articleID, restoreQuote: restoreQuote)
			}
		}
	}

	func finishStreaming(articleID: String, message: ChatMessage, restoreQuote: String?) async {
		defer {
			streamTask = nil
		}

		// Force the last throttled frame before swapping in the stored messages.
		renderStreamingRow()

		do {
			guard let messages = try await fetchStoredMessages(articleID: articleID) else {
				return
			}
			guard messages.contains(where: { $0.id == message.id }) else {
				isSending = false
				receivedDelta = false
				restoreQuoteIfNeeded(restoreQuote)
				updateSendingState()
				showError("发送失败：回复未保存到本地。")
				return
			}

			pendingAssistantText = nil
			pendingUserMessage = nil
			streamingRow = nil
			storedMessages = messages
			isSending = false
			receivedDelta = false
			updateSendingState()
			rebuildMessages()
		} catch {
			guard article?.articleID == articleID else {
				return
			}
			isSending = false
			receivedDelta = false
			restoreQuoteIfNeeded(restoreQuote)
			updateSendingState()
			showError("读取对话失败：\(error.localizedDescription)")
		}
	}

	func handleStreamFailure(_ error: Error, articleID: String, restoreQuote: String?) {
		defer {
			streamTask = nil
		}
		guard article?.articleID == articleID else {
			return
		}

		let cancelled = error is CancellationError
			|| (error as? URLError)?.code == .cancelled
			|| Task.isCancelled

		pendingAssistantText = nil
		pendingUserMessage = nil
		streamingRow = nil
		isSending = false
		receivedDelta = false
		if !cancelled {
			restoreQuoteIfNeeded(restoreQuote)
		}
		updateSendingState()
		rebuildMessages()

		if !cancelled {
			showError("发送失败：\(error.localizedDescription)")
		}
	}

	/// Reads messages without rebuilding; the caller applies them once.
	/// Returns nil when the article changed while the read was in flight.
	func fetchStoredMessages(articleID: String) async throws -> [ChatMessage]? {
		let messages = try await AIEnvironment.shared.store.chatMessages(for: articleID)
		guard article?.articleID == articleID else {
			return nil
		}
		return messages
	}

	func rebuildMessages(followScroll: Bool = true) {
		for subview in messagesStack.arrangedSubviews {
			messagesStack.removeArrangedSubview(subview)
			subview.removeFromSuperview()
		}
		streamingRow = nil

		if storedMessages.isEmpty, pendingUserMessage == nil, pendingAssistantText == nil {
			let hint = NSTextField(wrappingLabelWithString: "选择阅读任务，或输入问题开始对话。")
			hint.font = .systemFont(ofSize: 12)
			hint.textColor = .secondaryLabelColor
			hint.alignment = .center

			let subHint = NSTextField(wrappingLabelWithString: "任务在输入框上方，随时呼出，不占对话空间。")
			subHint.font = .systemFont(ofSize: 11)
			subHint.textColor = .tertiaryLabelColor
			subHint.alignment = .center

			let emptyStack = NSStackView(views: [hint, subHint])
			emptyStack.orientation = .vertical
			emptyStack.alignment = .centerX
			emptyStack.spacing = 7
			addMessageRow(emptyStack)
		} else {
			for message in storedMessages {
				addMessageRow(AIMessageRowView(message: message))
			}
			if let pendingUserMessage {
				addMessageRow(AIMessageRowView(message: pendingUserMessage))
			}
			if let pendingAssistantText {
				let row = AIMessageRowView(text: pendingAssistantText, isUser: false)
				streamingRow = row
				addMessageRow(row)
			}
		}

		messagesDocumentView.layoutSubtreeIfNeeded()
		if followScroll {
			scrollToBottom()
		}
	}

	func renderStreamingRow() {
		guard let pendingAssistantText else {
			return
		}
		let followScroll = isNearBottom
		if let streamingRow {
			streamingRow.update(text: pendingAssistantText)
			messagesDocumentView.layoutSubtreeIfNeeded()
			if followScroll {
				scrollToBottom()
			}
		} else {
			rebuildMessages(followScroll: false)
			if followScroll {
				scrollToBottom()
			}
		}
	}

	var isNearBottom: Bool {
		let documentHeight = messagesDocumentView.bounds.height
		let clipHeight = messagesScrollView.contentView.bounds.height
		let offset = messagesScrollView.contentView.bounds.origin.y
		return documentHeight - clipHeight - offset <= Self.streamFollowThreshold
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
		sendButton.isEnabled = !isSending && article != nil && hasSendableInput
		taskButton.isEnabled = !isSending
		if isSending {
			closeTray()
		}
	}

	var hasSendableInput: Bool {
		if pendingQuote != nil {
			return true
		}
		return !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	func updateInputState() {
		let hasArticle = article != nil
		inputTextView.isEditable = hasArticle
		quoteButton.isEnabled = hasArticle
		updateSendingState()
	}

	func updateQuoteChip() {
		guard let pendingQuote else {
			quoteLabel.stringValue = ""
			quoteChipView.isHidden = true
			return
		}
		quoteLabel.stringValue = pendingQuote
			.split(separator: "\n", omittingEmptySubsequences: false)
			.joined(separator: " ")
		quoteChipView.isHidden = false
	}

	func updateQuoteLabelWidth() {
		guard !quoteChipView.isHidden else {
			return
		}
		let width = max(60, quoteChipView.bounds.width - 70)
		guard abs(quoteLabel.preferredMaxLayoutWidth - width) > 0.5 else {
			return
		}
		quoteLabel.preferredMaxLayoutWidth = width
		quoteLabel.invalidateIntrinsicContentSize()
	}

	func restoreQuoteIfNeeded(_ quote: String?) {
		guard let quote, pendingQuote == nil else {
			return
		}
		pendingQuote = quote
		updateQuoteChip()
	}

	func makeQuoteBlock(_ text: String) -> String {
		text
			.split(separator: "\n", omittingEmptySubsequences: false)
			.map { "> \($0)" }
			.joined(separator: "\n")
	}

	func showError(_ message: String) {
		errorLabel.stringValue = message
		errorLabel.isHidden = false
	}
}

// MARK: - Actions

private extension AIChatViewController {

	@objc func sendFromInput() {
		guard hasSendableInput else {
			return
		}
		send(prompt: inputTextView.string)
	}

	@objc func removeQuote() {
		pendingQuote = nil
		updateQuoteChip()
		updateSendingState()
	}

	@objc func toggleTaskTray() {
		guard !isSending else {
			return
		}
		if isTrayOpen {
			closeTray()
		} else {
			openTray()
		}
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
		pendingQuote = text
		updateQuoteChip()
		updateSendingState()
		view.window?.makeFirstResponder(inputTextView)
	}

	func promptForNewCustomPrompt() {
		let dialog = AICustomPromptDialog(name: "", prompt: "")
		let alert = makeCustomPromptAlert(
			messageText: "新增自定义提示词",
			informativeText: "保存后出现在「自定义」分组，最多 \(AICustomPromptStore.maximumCount) 条。",
			dialog: dialog
		)
		guard runCustomPromptAlert(alert) == .alertFirstButtonReturn else {
			return
		}
		let name = dialog.nameField.stringValue
		let prompt = dialog.promptTextView.string
		guard customPromptStore.add(name: name, prompt: prompt) else {
			showError(customPromptErrorMessage(name: name, prompt: prompt))
			return
		}
		finishCustomPromptChange()
	}

	func promptForEditingCustomPrompt(at index: Int) {
		guard customPromptStore.prompts.indices.contains(index) else {
			return
		}
		let existing = customPromptStore.prompts[index]
		let dialog = AICustomPromptDialog(name: existing.name, prompt: existing.prompt)
		let alert = makeCustomPromptAlert(
			messageText: "编辑自定义提示词",
			informativeText: "修改后立即生效。",
			dialog: dialog
		)
		guard runCustomPromptAlert(alert) == .alertFirstButtonReturn else {
			return
		}
		let name = dialog.nameField.stringValue
		let prompt = dialog.promptTextView.string
		guard customPromptStore.update(at: index, name: name, prompt: prompt) else {
			showError(customPromptErrorMessage(name: name, prompt: prompt))
			return
		}
		finishCustomPromptChange()
	}

	func makeCustomPromptAlert(messageText: String, informativeText: String, dialog: AICustomPromptDialog) -> NSAlert {
		let alert = NSAlert()
		alert.messageText = messageText
		alert.informativeText = informativeText
		alert.accessoryView = dialog.accessoryView
		alert.addButton(withTitle: "保存")
		alert.addButton(withTitle: "取消")
		dialog.saveButton = alert.buttons.first
		dialog.updateSaveButton()
		alert.window.initialFirstResponder = dialog.nameField
		positionCustomPromptAlert(alert)
		return alert
	}

	/// Centers the alert over the AI pane instead of the whole window. NSAlert centers
	/// itself when the modal loop starts, so the move is queued to run after it does.
	func positionCustomPromptAlert(_ alert: NSAlert) {
		guard let hostWindow = view.window else {
			return
		}
		let alertWindow = alert.window
		let paneFrame = hostWindow.convertToScreen(view.convert(view.bounds, to: nil))
		DispatchQueue.main.async {
			let alertSize = alertWindow.frame.size
			var origin = NSPoint(x: paneFrame.midX - alertSize.width / 2, y: paneFrame.midY - alertSize.height / 2)
			if let screen = hostWindow.screen {
				let visibleFrame = screen.visibleFrame
				origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - alertSize.width)
				origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - alertSize.height)
			}
			alertWindow.setFrameOrigin(origin)
		}
	}

	/// Runs the alert modally and restores the tray's outside-click monitors afterwards.
	func runCustomPromptAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
		removeEventMonitors()
		let response = alert.runModal()
		if isTrayOpen {
			installEventMonitors()
		}
		return response
	}

	func customPromptErrorMessage(name: String, prompt: String) -> String {
		let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedName.isEmpty || trimmedPrompt.isEmpty {
			return "名称和提示词都不能为空。"
		}
		if trimmedName.count > AICustomPromptStore.maximumNameLength || trimmedPrompt.count > AICustomPromptStore.maximumPromptLength {
			return "名称最多 \(AICustomPromptStore.maximumNameLength) 字，提示词最多 \(AICustomPromptStore.maximumPromptLength) 字。"
		}
		if customPromptStore.prompts.contains(where: { $0.name == trimmedName }) {
			return "名称「\(trimmedName)」已存在，请换一个。"
		}
		return "自定义提示词已达上限（\(AICustomPromptStore.maximumCount) 条）。"
	}

	func finishCustomPromptChange() {
		errorLabel.isHidden = true
		updateTaskButtonCount()
		refreshTaskTray()
	}

	func deleteCustomPrompt(at index: Int) {
		customPromptStore.remove(at: index)
		updateTaskButtonCount()
		refreshTaskTray()
	}

	func updateTaskButtonCount() {
		taskButton.count = AIPrompts.readingTasks.count + customPromptStore.prompts.count
	}

	func refreshTaskTray() {
		guard isTrayOpen else {
			return
		}
		taskTray.reload(customPrompts: customPromptStore.prompts)
		view.needsLayout = true
		updateTrayHeight()
	}

	func openTray() {
		guard !isSending else {
			return
		}
		taskTray.reload(customPrompts: customPromptStore.prompts)
		isTrayOpen = true
		taskButton.isOpen = true
		taskTray.isHidden = false
		view.layoutSubtreeIfNeeded()
		updateTrayHeight()
		installEventMonitors()
	}

	func closeTray() {
		guard isTrayOpen else {
			return
		}
		isTrayOpen = false
		taskButton.isOpen = false
		taskTray.isHidden = true
		removeEventMonitors()
	}

	func updateTrayHeight() {
		guard let trayHeightConstraint, !taskTray.isHidden else {
			return
		}
		let buttonFrame = view.convert(taskButton.bounds, from: taskButton)
		let messagesFrame = view.convert(messagesScrollView.bounds, from: messagesScrollView)
		let trayBottom = buttonFrame.maxY - 9
		let availableHeight = messagesFrame.maxY - trayBottom - 4
		let contentHeight = taskTray.contentHeight
		let height = min(AITaskTrayView.maximumHeight, max(0, availableHeight), max(0, contentHeight))
		guard abs(trayHeightConstraint.constant - height) > 0.5 else {
			return
		}
		trayHeightConstraint.constant = height
	}

	func installEventMonitors() {
		removeEventMonitors()

		localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
			MainActor.assumeIsolated {
				guard let self, self.isTrayOpen else {
					return
				}
				guard !self.isPointInsideTrayOrButton(event.locationInWindow, eventWindow: event.window) else {
					return
				}
				self.closeTray()
			}
			return event
		}

		globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
			Task { @MainActor in
				self?.closeTray()
			}
		}

		escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			let closesTray = MainActor.assumeIsolated {
				guard let self, self.isTrayOpen, event.window === self.view.window, event.keyCode == 53 else {
					return false
				}
				self.closeTray()
				return true
			}
			return closesTray ? nil : event
		}
	}

	func removeEventMonitors() {
		if let localMouseMonitor {
			NSEvent.removeMonitor(localMouseMonitor)
			self.localMouseMonitor = nil
		}
		if let globalMouseMonitor {
			NSEvent.removeMonitor(globalMouseMonitor)
			self.globalMouseMonitor = nil
		}
		if let escapeKeyMonitor {
			NSEvent.removeMonitor(escapeKeyMonitor)
			self.escapeKeyMonitor = nil
		}
	}

	func isPointInsideTrayOrButton(_ locationInWindow: NSPoint, eventWindow: NSWindow?) -> Bool {
		guard eventWindow === view.window else {
			return false
		}
		let point = view.convert(locationInWindow, from: nil)
		let trayPoint = taskTray.convert(point, from: view)
		if taskTray.bounds.contains(trayPoint) {
			return true
		}
		let buttonPoint = taskButton.convert(point, from: view)
		return taskButton.bounds.contains(buttonPoint)
	}
}

// MARK: - NSTextViewDelegate

extension AIChatViewController: NSTextViewDelegate {

	func textDidChange(_ notification: Notification) {
		updateSendingState()
	}

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

// MARK: - Composer chrome

private final class AIQuoteChipView: NSView {

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.cornerRadius = 5
		applyColors()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyColors()
	}

	private func applyColors() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
		}
	}
}

/// Accessory view for the add/edit custom-prompt alert: a name field and a prompt text view,
/// each with a live character count. The save button is disabled while the name is empty.
@MainActor
private final class AICustomPromptDialog: NSObject, NSTextFieldDelegate, NSTextViewDelegate {

	let accessoryView: NSView
	let nameField = NSTextField()
	let promptTextView = NSTextView()
	weak var saveButton: NSButton?

	private let nameCountLabel = NSTextField(labelWithString: "")
	private let promptCountLabel = NSTextField(labelWithString: "")

	init(name: String, prompt: String) {
		accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 150))
		super.init()
		buildContent()
		nameField.stringValue = name
		promptTextView.string = prompt
		clampName()
		clampPrompt()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func updateSaveButton() {
		let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		saveButton?.isEnabled = !trimmedName.isEmpty
	}

	func controlTextDidChange(_ notification: Notification) {
		clampName()
		updateSaveButton()
	}

	func textDidChange(_ notification: Notification) {
		clampPrompt()
	}
}

private extension AICustomPromptDialog {

	func buildContent() {
		nameField.placeholderString = "例如：一句话概括"
		nameField.font = .systemFont(ofSize: 12)
		nameField.delegate = self
		nameField.translatesAutoresizingMaskIntoConstraints = false
		nameField.heightAnchor.constraint(equalToConstant: 24).isActive = true

		promptTextView.isRichText = false
		promptTextView.font = .systemFont(ofSize: 12)
		promptTextView.textContainerInset = NSSize(width: 4, height: 4)
		promptTextView.isAutomaticQuoteSubstitutionEnabled = false
		promptTextView.isVerticallyResizable = true
		promptTextView.isHorizontallyResizable = false
		promptTextView.autoresizingMask = [.width]
		promptTextView.textContainer?.widthTracksTextView = true
		promptTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
		promptTextView.delegate = self

		let promptScrollView = NSScrollView()
		promptScrollView.hasVerticalScroller = true
		promptScrollView.autohidesScrollers = true
		promptScrollView.borderType = .bezelBorder
		promptScrollView.documentView = promptTextView
		promptScrollView.translatesAutoresizingMaskIntoConstraints = false
		promptScrollView.heightAnchor.constraint(equalToConstant: 78).isActive = true

		let stack = NSStackView(views: [
			makeFieldHead("名称", countLabel: nameCountLabel),
			nameField,
			makeFieldHead("提示词", countLabel: promptCountLabel),
			promptScrollView
		])
		stack.orientation = .vertical
		stack.alignment = .width
		stack.spacing = 0
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.setCustomSpacing(4, after: stack.arrangedSubviews[0])
		stack.setCustomSpacing(12, after: nameField)
		stack.setCustomSpacing(4, after: stack.arrangedSubviews[2])
		accessoryView.addSubview(stack)

		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: accessoryView.topAnchor),
			stack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor)
		])
	}

	func makeFieldHead(_ title: String, countLabel: NSTextField) -> NSView {
		let titleLabel = NSTextField(labelWithString: title)
		titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
		titleLabel.textColor = .secondaryLabelColor

		countLabel.font = .systemFont(ofSize: 10)
		countLabel.textColor = .tertiaryLabelColor

		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let row = NSStackView(views: [titleLabel, spacer, countLabel])
		row.orientation = .horizontal
		row.alignment = .firstBaseline
		row.spacing = 6
		return row
	}

	func clampName() {
		let text = nameField.stringValue
		if text.count > AICustomPromptStore.maximumNameLength {
			nameField.stringValue = String(text.prefix(AICustomPromptStore.maximumNameLength))
			if let editor = nameField.currentEditor() {
				editor.selectedRange = NSRange(location: (nameField.stringValue as NSString).length, length: 0)
			}
		}
		nameCountLabel.stringValue = "\(nameField.stringValue.count) / \(AICustomPromptStore.maximumNameLength)"
	}

	func clampPrompt() {
		let text = promptTextView.string
		if text.count > AICustomPromptStore.maximumPromptLength {
			let clamped = String(text.prefix(AICustomPromptStore.maximumPromptLength))
			promptTextView.string = clamped
			promptTextView.setSelectedRange(NSRange(location: (clamped as NSString).length, length: 0))
		}
		promptCountLabel.stringValue = "\(promptTextView.string.count) / \(AICustomPromptStore.maximumPromptLength)"
	}
}

private final class AIComposerBoxView: NSView {

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.cornerRadius = 6
		layer?.borderWidth = 1
		applyColors()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyColors()
	}

	private func applyColors() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
			layer?.borderColor = NSColor.separatorColor.cgColor
		}
	}
}
