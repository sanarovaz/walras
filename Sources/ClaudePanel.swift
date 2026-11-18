import AppKit

// MARK: - Model

/// A change Claude proposes. Claude has no tool that can write files: only Walras
/// applies an edit, into the open buffer, after the user accepts it.
struct ClaudeEdit: Codable {
    enum State: String, Codable {
        case pending, applied, rejected, conflict
    }

    /// Absent for a text change. A move keeps its source in `file` and its destination in `new`.
    enum Kind: String, Codable {
        case newFolder, move
    }

    var id = UUID()
    let file: String
    let old: String
    let new: String
    var state = State.pending
    var kind: Kind? = nil
}

struct ChatEntry: Codable {
    enum Role: String, Codable {
        case user, assistant, error
    }

    var id = UUID()
    let role: Role
    var text: String
    var edits: [ClaudeEdit] = []
}

private struct ChatStore: Codable {
    var sessionID: String?
    var entries: [ChatEntry] = []
    var model = ""
}

/// Runs the Claude Code that the user installed and signed in to, one process per turn.
final class ClaudeRunner {
    var onEvent: (([String: Any]) -> Void)?
    var onFinish: ((_ status: Int32, _ errorOutput: String) -> Void)?

    private var process: Process?

    private static let systemPrompt = """
    You are the assistant inside Walras, a local LaTeX editor on the user's Mac. The working directory is the user's project.
    You can read with Read, Grep and Glob. You cannot modify anything directly.
    Read only what the request needs, to spare the user's usage limits: start from the open file and selection given in the context, and don't scan the whole project unless asked.
    To propose a change, write one block per change in your reply, in exactly this form:
    <walras-edit file="path/relative/to/project.tex"><old>exact current text</old><new>replacement text</new></walras-edit>
    Rules for each block:
    - `old` must match the file character by character and occur only once in it. Keep it short, with just enough surrounding text to be unique.
    - For a new file, leave `old` empty and put its contents in `new`.
    To propose creating a folder or moving or renaming a file or folder inside the project, write:
    <walras-mkdir path="folder/relative/to/project"/>
    <walras-move from="old/relative/path" to="new/relative/path"/>
    A move doesn't update references: when one breaks an \\input, \\include, \\includegraphics or \\bibliography, also propose the matching text edits. Don't propose deleting anything. All paths stay inside the project.
    - Don't repeat a proposed change as a code block, and never say it has been applied: the user approves each block in the interface.
    Reply in the language the user writes in, and be concise. Put LaTeX in `backticks` when you mention it in prose.
    """

    /// Finds `claude` even though apps opened from Finder don't inherit the shell's PATH.
    static func findExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let places = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/bin"]
        for place in places where FileManager.default.isExecutableFile(atPath: place + "/claude") {
            return place + "/claude"
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func start(executable: String, directory: URL, prompt: String, sessionID: String?, model: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob",
            "--permission-mode", "dontAsk", "--strict-mcp-config",
            "--append-system-prompt", Self.systemPrompt,
        ]
        if let sessionID { arguments += ["--resume", sessionID] }
        if !model.isEmpty { arguments += ["--model", model] }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (Compiler.searchDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        // This panel always uses the signed-in account, never a key left in the environment.
        environment["ANTHROPIC_API_KEY"] = nil
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Reads on one queue, so the last lines can't be lost or reordered when the process ends.
        let reader = DispatchQueue(label: "walras.claude.output")
        reader.async { [weak self] in
            var pending = Data()
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.subdata(in: pending.startIndex..<newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    DispatchQueue.main.async { self?.onEvent?(json) }
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            reader.sync {}
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errorData, as: UTF8.self)
            DispatchQueue.main.async {
                self?.process = nil
                self?.onFinish?(finished.terminationStatus, errorText)
            }
        }

        do {
            try process.run()
            self.process = process
            let data = Data(prompt.utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
            }
        } catch {
            onFinish?(-1, error.localizedDescription)
        }
    }

    var isRunning: Bool { process?.isRunning == true }

    func stop() {
        process?.interrupt()
    }
}

// MARK: - Views

/// A selectable label that wraps to the width it is given and reports its true height.
final class WrappingLabel: NSTextField {
    convenience init(attributed: NSAttributedString) {
        self.init(wrappingLabelWithString: "")
        attributedStringValue = attributed
        isSelectable = true
        allowsEditingTextAttributes = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// The message box: return sends, shift-return makes a new line.
private final class ChatInputView: NSTextView {
    var onSend: (() -> Void)?

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onSend?()
        } else {
            super.doCommand(by: selector)
        }
    }
}

final class ClaudePanelViewController: NSViewController, NSTextViewDelegate {
    var projectRoot: URL!
    /// Saves everything and returns the description of the current state for Claude.
    var contextProvider: (() -> String)?
    /// Applies an accepted edit; false means the text no longer matches.
    var applyEdit: ((ClaudeEdit) -> Bool)?
    var showStatus: ((String) -> Void)?

    private let runner = ClaudeRunner()
    private var store = ChatStore()
    private var stack: FlippedStack!
    private var scroll: NSScrollView!
    private var input: ChatInputView!
    private var placeholder: NSTextField!
    private var sendButton: NSButton!
    private var modelPopup: NSPopUpButton!
    private var activityLabel: NSTextField!
    private let thinkingSpinner = NSProgressIndicator()
    private var thinkingRow: NSStackView!
    private var activityText = ""
    private var runStart = Date()
    private var elapsedTimer: Timer?
    private var streamLabel: WrappingLabel?
    private var streamText = ""
    private var isRunning = false
    private var outcomes: [String] = []

    private static let models: [(title: String, value: String)] = [
        (L("Modelo predeterminado", "Default Model"), ""), ("Sonnet", "sonnet"), ("Opus", "opus"), ("Haiku", "haiku"),
    ]

    private static let folderPattern = try! NSRegularExpression(pattern: "<walras-mkdir\\s+path=\"([^\"]+)\"\\s*/>")
    private static let movePattern = try! NSRegularExpression(
        pattern: "<walras-move\\s+from=\"([^\"]+)\"\\s+to=\"([^\"]+)\"\\s*/>")
    private static let editPattern = try! NSRegularExpression(
        pattern: "<walras-edit\\s+file=\"([^\"]+)\"\\s*>\\s*<old>(.*?)</old>\\s*<new>(.*?)</new>\\s*</walras-edit>",
        options: [.dotMatchesLineSeparators])

    override func loadView() {
        let root = ThemedBackgroundView { $0.background }

        let title = NSTextField(labelWithString: "Claude")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = EditorTheme.current.comment
        activityLabel = NSTextField(labelWithString: "")
        activityLabel.font = .systemFont(ofSize: 11)
        activityLabel.textColor = EditorTheme.current.comment
        activityLabel.font = .systemFont(ofSize: 12)
        activityLabel.lineBreakMode = .byTruncatingMiddle
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        thinkingSpinner.style = .spinning
        thinkingSpinner.controlSize = .small
        thinkingSpinner.isDisplayedWhenStopped = false
        thinkingRow = NSStackView(views: [thinkingSpinner, activityLabel])
        thinkingRow.orientation = .horizontal
        thinkingRow.spacing = 7
        thinkingRow.alignment = .centerY
        thinkingRow.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modelPopup.controlSize = .small
        modelPopup.font = .systemFont(ofSize: 11)
        modelPopup.isBordered = false
        modelPopup.addItems(withTitles: Self.models.map { $0.title })
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        let newChat = NSButton(title: L("Nuevo chat", "New Chat"), target: self, action: #selector(newChatPressed))
        newChat.controlSize = .small
        newChat.font = .systemFont(ofSize: 11)
        newChat.isBordered = false
        newChat.contentTintColor = EditorTheme.current.icon

        let header = NSStackView(views: [title, spacer, modelPopup, newChat])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false

        stack = FlippedStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView

        // The message box has its own surface, set apart from Claude's replies.
        let composer = ThemedBackgroundView { $0.sidebar }
        composer.translatesAutoresizingMaskIntoConstraints = false
        let composerLine = ThemedBackgroundView { $0.separator }
        composerLine.translatesAutoresizingMaskIntoConstraints = false
        let inputBox = ThemedBackgroundView { $0.background }
        inputBox.wantsLayer = true
        inputBox.layer?.cornerRadius = 8
        inputBox.layer?.masksToBounds = true
        inputBox.translatesAutoresizingMaskIntoConstraints = false

        let inputScroll = NSTextView.scrollableTextView()
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        input = ChatInputView(frame: .zero, textContainer: container)
        input.isRichText = false
        input.allowsUndo = true
        input.font = .systemFont(ofSize: 13)
        input.textColor = EditorTheme.current.text
        input.insertionPointColor = EditorTheme.current.text
        input.drawsBackground = false
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.textContainerInset = NSSize(width: 0, height: 4)
        input.delegate = self
        input.onSend = { [weak self] in self?.sendOrStop() }
        inputScroll.documentView = input

        placeholder = NSTextField(labelWithString: L("Preguntale a Claude sobre este proyecto", "Ask Claude about this project"))
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = EditorTheme.current.comment
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        sendButton = NSButton(image: Self.symbol("arrow.up.circle.fill"), target: self, action: #selector(sendPressed))
        sendButton.isBordered = false
        sendButton.imagePosition = .imageOnly
        sendButton.contentTintColor = EditorTheme.current.accent
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        // Below required, so that what's inside the chat can never hold the column's width:
        // a split view's dividers lose to any stronger constraint on what they contain.
        let stackWidth = stack.widthAnchor.constraint(equalTo: clip.widthAnchor)
        stackWidth.priority = NSLayoutConstraint.Priority(rawValue: 999)
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(composer)
        composer.addSubview(composerLine)
        composer.addSubview(inputBox)
        inputBox.addSubview(inputScroll)
        inputBox.addSubview(placeholder)
        inputBox.addSubview(sendButton)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: composer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            composerLine.topAnchor.constraint(equalTo: composer.topAnchor),
            composerLine.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            composerLine.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            composerLine.heightAnchor.constraint(equalToConstant: 1),
            inputBox.topAnchor.constraint(equalTo: composer.topAnchor, constant: 10),
            inputBox.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -10),
            inputBox.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            inputBox.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stackWidth,
            inputScroll.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 5),
            inputScroll.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputScroll.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: -5),
            inputScroll.heightAnchor.constraint(equalToConstant: 46),
            placeholder.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor, constant: 5),
            placeholder.topAnchor.constraint(equalTo: inputScroll.topAnchor, constant: 4),
            sendButton.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: -7),
            sendButton.widthAnchor.constraint(equalToConstant: 24),
            sendButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = root

        runner.onEvent = { [weak self] event in self?.handle(event) }
        runner.onFinish = { [weak self] status, errors in self?.finish(status: status, errors: errors) }
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? NSImage()
    }

    func focusInput() {
        view.window?.makeFirstResponder(input)
    }

    func applyTheme() {
        _ = view
        let theme = EditorTheme.current
        input.textColor = theme.text
        input.insertionPointColor = theme.text
        placeholder.textColor = theme.comment
        sendButton.contentTintColor = theme.accent
        view.needsDisplay = true
        render()
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !input.string.isEmpty
    }

    // MARK: - Persistence

    /// Conversations live in Application Support, never inside the project folder.
    private var storeURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("Walras/Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = projectRoot.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent(key + ".json")
    }

    func loadConversation() {
        _ = view
        if let url = storeURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(ChatStore.self, from: data) {
            store = saved
        }
        if let index = Self.models.firstIndex(where: { $0.value == store.model }) { modelPopup.selectItem(at: index) }
        render()
    }

    private func saveConversation() {
        guard let url = storeURL, let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Actions

    @objc private func modelChanged() {
        store.model = Self.models[max(0, modelPopup.indexOfSelectedItem)].value
        saveConversation()
    }

    @objc private func newChatPressed() {
        guard !isRunning else { return }
        store.entries = []
        store.sessionID = nil
        outcomes = []
        saveConversation()
        render()
        focusInput()
    }

    @objc private func sendPressed() {
        sendOrStop()
    }

    private func sendOrStop() {
        if isRunning {
            runner.stop()
            return
        }
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.string = ""
        placeholder.isHidden = false
        send(text)
    }

    private func send(_ text: String) {
        var preface = contextProvider?() ?? ""
        if !outcomes.isEmpty {
            preface += "\nOutcome of your proposed edits since your last message:\n" + outcomes.joined(separator: "\n") + "\n"
            outcomes = []
        }
        store.entries.append(ChatEntry(role: .user, text: text))
        store.entries.append(ChatEntry(role: .assistant, text: ""))
        streamText = ""
        setRunning(true)
        setActivity(L("Pensando…", "Thinking…"))
        render()
        scrollToBottom()
        saveConversation()

        let prompt = "[Context from Walras]\n\(preface)\n[User message]\n\(text)"
        let directory = projectRoot!
        let session = store.sessionID
        let model = store.model
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let executable = ClaudeRunner.findExecutable()
            DispatchQueue.main.async {
                guard let self else { return }
                guard let executable else {
                    self.fail(L("""
                    No encontré Claude Code en esta Mac. Para instalarlo, pegá esto en Terminal:

                    curl -fsSL https://claude.ai/install.sh | bash

                    Después escribí claude en una ventana nueva de Terminal, iniciá sesión una vez y volvé a intentar.
                    """, """
                    Claude Code wasn't found on this Mac. To install it, paste this into Terminal:

                    curl -fsSL https://claude.ai/install.sh | bash

                    Then type claude in a new Terminal window, sign in once and try again.
                    """))
                    return
                }
                self.runner.start(executable: executable, directory: directory, prompt: prompt, sessionID: session, model: model)
            }
        }
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        sendButton.image = Self.symbol(running ? "stop.circle.fill" : "arrow.up.circle.fill")
        sendButton.toolTip = running ? L("Detener", "Stop") : L("Enviar (↩)", "Send (↩)")
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if running {
            runStart = Date()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshActivityLabel() }
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
            thinkingSpinner.startAnimation(nil)
        } else {
            thinkingSpinner.stopAnimation(nil)
            thinkingRow.removeFromSuperview()
            setActivity("")
        }
    }

    private func setActivity(_ text: String) {
        activityText = text
        refreshActivityLabel()
    }

    /// The running seconds show that the answer is still on its way during a long silence.
    private func refreshActivityLabel() {
        let seconds = Int(Date().timeIntervalSince(runStart))
        activityLabel.stringValue = seconds >= 2 ? "\(activityText) \(seconds) s" : activityText
    }

    private func fail(_ message: String) {
        if store.entries.last?.role == .assistant, store.entries.last?.text.isEmpty == true, store.entries.last?.edits.isEmpty == true {
            store.entries.removeLast()
        }
        store.entries.append(ChatEntry(role: .error, text: message))
        setRunning(false)
        saveConversation()
        render()
        scrollToBottom()
    }

    // MARK: - Stream

    private func handle(_ event: [String: Any]) {
        if let session = event["session_id"] as? String { store.sessionID = session }
        switch event["type"] as? String {
        case "stream_event":
            guard let inner = event["event"] as? [String: Any] else { return }
            // Only the main conversation is shown.
            if event["parent_tool_use_id"] is String { return }
            if inner["type"] as? String == "message_start", !streamText.isEmpty, !streamText.hasSuffix("\n\n") {
                streamText += "\n\n"
            }
            if inner["type"] as? String == "content_block_delta",
               let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                streamText += text
                updateStreamingText()
            }
        case "assistant":
            guard let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_use" {
                let inputs = block["input"] as? [String: Any]
                let target = (inputs?["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
                    ?? inputs?["pattern"] as? String ?? ""
                setActivity(L("Leyendo", "Reading") + " " + target)
            }
        case "result":
            if event["is_error"] as? Bool == true {
                let reason = event["result"] as? String ?? L("Claude Code devolvió un error.", "Claude Code returned an error.")
                pendingError = reason
            } else if streamText.isEmpty, let result = event["result"] as? String {
                streamText = result
            }
        default:
            break
        }
    }

    private var pendingError: String?

    private func finish(status: Int32, errors: String) {
        let parsed = parseEdits(streamText)
        if !store.entries.isEmpty, store.entries[store.entries.count - 1].role == .assistant {
            store.entries[store.entries.count - 1].text = parsed.text
            store.entries[store.entries.count - 1].edits = parsed.edits
        }
        streamLabel = nil
        streamText = ""

        if let reason = pendingError {
            pendingError = nil
            fail(Self.explain(reason))
            return
        }
        // Stopping with the button also ends the process with a non-zero status.
        if status != 0, parsed.text.isEmpty, parsed.edits.isEmpty {
            let detail = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            fail(Self.explain(detail.isEmpty ? L("Claude Code se detuvo.", "Claude Code stopped.") : detail))
            return
        }
        setRunning(false)
        saveConversation()
        render()
        scrollToBottom()
    }

    private static func explain(_ reason: String) -> String {
        let lowered = reason.lowercased()
        if lowered.contains("login") || lowered.contains("log in") || lowered.contains("authenticat") {
            return reason + L("\n\nEscribí claude en Terminal e iniciá sesión con tu cuenta.", "\n\nType claude in Terminal and sign in with your account.")
        }
        return reason
    }

    /// Hides the blocks while they arrive: they become cards when the reply ends.
    private func visibleStreamText() -> String {
        var text = Self.withoutOperations(streamText)
        if let open = text.range(of: "<walras-") { text = String(text[..<open.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateStreamingText() {
        streamLabel?.attributedStringValue = Self.styled(visibleStreamText())
        if streamText.contains("<walras-") {
            setActivity(L("Preparando un cambio…", "Preparing a change…"))
        } else if !visibleStreamText().isEmpty {
            setActivity(L("Escribiendo…", "Writing…"))
        }
        scrollToBottom()
    }

    private func parseEdits(_ raw: String) -> (text: String, edits: [ClaudeEdit]) {
        let text = raw as NSString
        let whole = NSRange(location: 0, length: text.length)
        var found: [(location: Int, edit: ClaudeEdit)] = []
        for match in Self.editPattern.matches(in: raw, options: [], range: whole) {
            found.append((match.range.location, ClaudeEdit(file: text.substring(with: match.range(at: 1)),
                                                           old: text.substring(with: match.range(at: 2)),
                                                           new: text.substring(with: match.range(at: 3)))))
        }
        for match in Self.folderPattern.matches(in: raw, options: [], range: whole) {
            found.append((match.range.location, ClaudeEdit(file: text.substring(with: match.range(at: 1)),
                                                           old: "", new: "", kind: .newFolder)))
        }
        for match in Self.movePattern.matches(in: raw, options: [], range: whole) {
            found.append((match.range.location, ClaudeEdit(file: text.substring(with: match.range(at: 1)), old: "",
                                                           new: text.substring(with: match.range(at: 2)), kind: .move)))
        }
        // In the order Claude wrote them: a move may depend on a folder created just before.
        let edits = found.sorted { $0.location < $1.location }.map { $0.edit }
        return (Self.withoutOperations(raw).trimmingCharacters(in: .whitespacesAndNewlines), edits)
    }

    private static func withoutOperations(_ raw: String) -> String {
        var text = raw
        for pattern in [editPattern, folderPattern, movePattern] {
            text = pattern.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        return text
    }

    // MARK: - Edits

    private func update(entry entryID: UUID, edit editID: UUID, _ change: (inout ClaudeEdit) -> Void) -> ClaudeEdit? {
        guard let entryIndex = store.entries.firstIndex(where: { $0.id == entryID }),
              let editIndex = store.entries[entryIndex].edits.firstIndex(where: { $0.id == editID }) else { return nil }
        change(&store.entries[entryIndex].edits[editIndex])
        return store.entries[entryIndex].edits[editIndex]
    }

    private func decide(entry: UUID, edit: UUID, accept: Bool) {
        guard let current = update(entry: entry, edit: edit, { _ in }), current.state == .pending else { return }
        if accept {
            if applyEdit?(current) == true {
                _ = update(entry: entry, edit: edit) { $0.state = .applied }
                switch current.kind {
                case .newFolder: outcomes.append("- Accepted: the folder \(current.file) now exists.")
                case .move: outcomes.append("- Accepted: \(current.file) was moved to \(current.new).")
                case nil: outcomes.append("- Accepted and applied a change to \(current.file). The file now contains your new text.")
                }
            } else {
                _ = update(entry: entry, edit: edit) { $0.state = .conflict }
            }
        } else {
            _ = update(entry: entry, edit: edit) { $0.state = .rejected }
            outcomes.append("- Rejected your proposal for \(current.file).")
        }
        saveConversation()
        render()
    }

    private func acceptAll(entry: UUID) {
        guard let edits = store.entries.first(where: { $0.id == entry })?.edits else { return }
        for edit in edits where edit.state == .pending {
            decide(entry: entry, edit: edit.id, accept: true)
        }
    }

    private func askAgain(file: String) {
        send(L("El texto de ese cambio en \(file) ya no coincide con el archivo. Volvé a leerlo y proponelo de nuevo.",
               "The text of that change in \(file) no longer matches the file. Read it again and propose it anew."))
    }

    // MARK: - Rendering

    /// Only **bold** and `code` are interpreted, so that LaTeX is never altered by Markdown.
    private static func styled(_ text: String) -> NSAttributedString {
        let theme = EditorTheme.current
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.text,
        ])
        func apply(_ pattern: String, _ attributes: [NSAttributedString.Key: Any]) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let matches = regex.matches(in: result.string, options: [], range: NSRange(location: 0, length: result.length))
            for match in matches.reversed() {
                let inner = (result.string as NSString).substring(with: match.range(at: 1))
                let replacement = NSAttributedString(string: inner, attributes: attributes)
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }
        apply("`([^`\\n]+)`", [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: theme.command])
        apply("\\*\\*([^*\\n]+)\\*\\*", [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: theme.text])
        return result
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    private func render() {
        guard stack != nil else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        streamLabel = nil
        let theme = EditorTheme.current

        if store.entries.isEmpty {
            let hint = NSAttributedString(string: L(
                "Claude puede leer este proyecto y proponerte cambios. Nada se modifica hasta que lo aceptes.",
                "Claude can read this project and propose changes. Nothing changes until you accept it."),
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.comment])
            addFullWidth(WrappingLabel(attributed: hint))
        }

        for (index, entry) in store.entries.enumerated() {
            switch entry.role {
            case .user:
                let text = NSAttributedString(string: entry.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.text,
                ])
                let label = WrappingLabel(attributed: text)
                let bubble = ThemedBackgroundView { $0.selection }
                bubble.wantsLayer = true
                bubble.layer?.cornerRadius = 8
                bubble.layer?.masksToBounds = true
                bubble.translatesAutoresizingMaskIntoConstraints = false
                bubble.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
                    label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
                    label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
                ])
                addFullWidth(bubble)
            case .error:
                let text = NSAttributedString(string: entry.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed,
                ])
                addFullWidth(WrappingLabel(attributed: text))
            case .assistant:
                let isStreaming = isRunning && index == store.entries.count - 1
                if isStreaming {
                    let label = WrappingLabel(attributed: Self.styled(visibleStreamText()))
                    addFullWidth(label)
                    streamLabel = label
                } else if !entry.text.isEmpty {
                    addFullWidth(WrappingLabel(attributed: Self.styled(entry.text)))
                }
                for edit in entry.edits { addFullWidth(card(for: edit, entry: entry.id)) }
                if entry.edits.filter({ $0.state == .pending }).count >= 2 {
                    let all = ActionButton(title: L("Aceptar todos", "Accept All")) { [weak self] in self?.acceptAll(entry: entry.id) }
                    stack.addArrangedSubview(all)
                }
            }
        }
        if isRunning {
            activityLabel.textColor = theme.comment
            addFullWidth(thinkingRow)
        }
    }

    private func card(for edit: ClaudeEdit, entry: UUID) -> NSView {
        let theme = EditorTheme.current
        let card = ThemedBackgroundView { $0.sidebar }
        card.wantsLayer = true
        card.layer?.cornerRadius = 7
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let heading: String
        switch edit.kind {
        case .newFolder: heading = L("Nueva carpeta: \(edit.file)", "New folder: \(edit.file)")
        case .move: heading = L("Mover: \(edit.file) → \(edit.new)", "Move: \(edit.file) → \(edit.new)")
        case nil: heading = edit.file
        }
        let fileLabel = NSTextField(labelWithString: heading)
        fileLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        fileLabel.textColor = theme.text
        fileLabel.lineBreakMode = .byTruncatingMiddle

        let diff = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        func add(_ text: String, _ sign: String, _ color: NSColor) {
            guard !text.isEmpty else { return }
            for line in text.components(separatedBy: "\n") {
                if diff.length > 0 { diff.append(NSAttributedString(string: "\n")) }
                diff.append(NSAttributedString(string: "\(sign) \(line)", attributes: [.font: mono, .foregroundColor: color]))
            }
        }
        if edit.kind == nil {
            add(edit.old, "−", .systemRed)
            add(edit.new, "+", .systemGreen)
        }
        let diffLabel = WrappingLabel(attributed: diff)

        let controls = NSStackView()
        controls.spacing = 6
        switch edit.state {
        case .pending:
            controls.addArrangedSubview(ActionButton(title: L("Aceptar", "Accept")) { [weak self] in
                self?.decide(entry: entry, edit: edit.id, accept: true)
            })
            controls.addArrangedSubview(ActionButton(title: L("Rechazar", "Reject")) { [weak self] in
                self?.decide(entry: entry, edit: edit.id, accept: false)
            })
        case .applied:
            let done = edit.kind == nil ? L("Aplicado · ⌘Z para deshacer", "Applied · ⌘Z to undo") : L("Hecho", "Done")
            controls.addArrangedSubview(Self.stateLabel(done, theme.comment))
        case .rejected:
            controls.addArrangedSubview(Self.stateLabel(L("Rechazado", "Rejected"), theme.comment))
        case .conflict:
            let reason = edit.kind == nil
                ? L("El archivo cambió; no se aplicó", "The file changed; not applied")
                : L("No se pudo hacer: revisá que el origen exista y el destino no", "Couldn't do it: check that the source exists and the destination doesn't")
            controls.addArrangedSubview(Self.stateLabel(reason, .systemOrange))
            if edit.kind == nil {
                controls.addArrangedSubview(ActionButton(title: L("Pedir de nuevo", "Ask Again")) { [weak self] in
                    self?.askAgain(file: edit.file)
                })
            }
        }

        let content = NSStackView(views: edit.kind == nil ? [fileLabel, diffLabel, controls] : [fileLabel, controls])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
        if edit.kind == nil { diffLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        return card
    }

    private static func stateLabel(_ text: String, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = color
        return label
    }

    private func scrollToBottom() {
        view.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let y = max(0, stack.fittingSize.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

/// A small button that runs a closure.
private final class ActionButton: NSButton {
    private var action2: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        action2 = handler
        target = self
        action = #selector(pressed)
        controlSize = .small
        font = .systemFont(ofSize: 11)
    }

    @objc private func pressed() {
        action2?()
    }
}

// MARK: - Window integration

extension ProjectWindowController {
    /// Describes what the user is looking at, after saving so Claude reads the latest text.
    func claudeContext() -> String {
        saveAll(interactive: false)
        var lines: [String] = []
        if let main = compileTarget() { lines.append("Main file: \(relativePath(main))") }
        if let current = editor.current {
            let position = editor.caretSnapshot()
            lines.append("Open file: \(relativePath(current.url)), line \(position.line)")
            if !position.selection.isEmpty {
                lines.append("Selected text:\n\(String(position.selection.prefix(4000)))")
            }
        }
        let errors = lastCompileErrorsForClaude()
        if !errors.isEmpty { lines.append("Latest compilation errors:\n\(errors)") }
        return lines.joined(separator: "\n")
    }

    private func insideProject(_ relative: String) -> URL? {
        let url = root.appendingPathComponent(relative).standardizedFileURL
        return url.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
    }

    func applyClaudeEdit(_ edit: ClaudeEdit) -> Bool {
        let fm = FileManager.default
        switch edit.kind {
        case .newFolder:
            guard let folder = insideProject(edit.file) else { return false }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return false
            }
            syncWithDisk()
            return true
        case .move:
            guard let source = insideProject(edit.file), let target = insideProject(edit.new),
                  fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { return false }
            saveAll(interactive: true)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: target)
            } catch {
                return false
            }
            afterMove(from: source, to: target)
            syncWithDisk()
            return true
        case nil:
            break
        }
        let url = root.appendingPathComponent(edit.file).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), ProjectFiles.isText(url) else { return false }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if edit.old.isEmpty {
            guard !exists else { return false }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(edit.new.utf8).write(to: url)
            } catch {
                return false
            }
            syncWithDisk()
            open(url)
            return true
        }
        guard exists else { return false }
        history.record(url)
        open(url)
        return editor.replace(old: edit.old, with: edit.new)
    }
}
