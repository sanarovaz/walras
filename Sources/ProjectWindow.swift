import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - PDF pane

/// A PDF view that reports ⌘-clicks instead of treating them as selection.
final class ClickablePDFView: PDFView {
    /// Page number from 1, point from the page's top left, and the clicked word.
    var onCommandClick: ((_ page: Int, _ x: Double, _ y: Double, _ word: String?) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandClick, let document else {
            super.mouseDown(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard let clicked = self.page(for: location, nearest: true) else { return }
        let point = convert(location, to: clicked)
        let box = clicked.bounds(for: .mediaBox)
        let word = clicked.selectionForWord(at: point)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommandClick(document.index(for: clicked) + 1, Double(point.x - box.minX), Double(box.maxY - point.y), word)
    }
}

final class PDFPaneViewController: NSViewController {
    let pdfView = ClickablePDFView()
    private let placeholder = NSTextField(labelWithString: L("Recompilá con ⌘R para ver el PDF", "Recompile with ⌘R to see the PDF"))

    private let pageIndicator = NSVisualEffectView()
    private let pageLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = ThemedBackgroundView { $0.pdfBackground }
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = EditorTheme.current.pdfBackground
        pdfView.pageShadowsEnabled = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 22, left: 30, bottom: 22, right: 30)
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.textColor = EditorTheme.current.comment
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        pageIndicator.material = .hudWindow
        pageIndicator.blendingMode = .withinWindow
        pageIndicator.state = .active
        pageIndicator.wantsLayer = true
        pageIndicator.layer?.cornerRadius = 7
        pageIndicator.layer?.masksToBounds = true
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        pageIndicator.isHidden = true
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .labelColor
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageIndicator.addSubview(pageLabel)

        root.addSubview(pdfView)
        root.addSubview(placeholder)
        root.addSubview(pageIndicator)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            pageIndicator.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            pageIndicator.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            pageLabel.topAnchor.constraint(equalTo: pageIndicator.topAnchor, constant: 5),
            pageLabel.bottomAnchor.constraint(equalTo: pageIndicator.bottomAnchor, constant: -5),
            pageLabel.leadingAnchor.constraint(equalTo: pageIndicator.leadingAnchor, constant: 11),
            pageLabel.trailingAnchor.constraint(equalTo: pageIndicator.trailingAnchor, constant: -11),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
    }

    func applyTheme() {
        _ = view
        pdfView.backgroundColor = EditorTheme.current.pdfBackground
        placeholder.textColor = EditorTheme.current.comment
        view.needsDisplay = true
    }

    /// Scrolls to a box given from the page's top left and flashes it, without changing the zoom.
    func reveal(page number: Int, left: Double, bottom: Double, width: Double, height: Double) {
        guard let page = pdfView.document?.page(at: number - 1) else { return }
        let box = page.bounds(for: .mediaBox)
        let rect = NSRect(x: box.minX + left, y: box.maxY - bottom, width: width, height: max(height, 10))
        pdfView.go(to: rect, on: page)
        guard let selection = page.selection(for: rect), selection.string?.isEmpty == false else { return }
        pdfView.setCurrentSelection(selection, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.pdfView.currentSelection === selection { self?.pdfView.clearSelection() }
        }
    }

    @objc private func pageChanged() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        pageLabel.stringValue = L("Página \(document.index(for: page) + 1) de \(document.pageCount)", "Page \(document.index(for: page) + 1) of \(document.pageCount)")
        pageIndicator.isHidden = false
    }

    /// Replaces the document while keeping the page and zoom, so recompiling
    /// does not make the reader lose their place.
    func display(_ data: Data) {
        guard let document = PDFDocument(data: data) else { return }
        placeholder.isHidden = true

        let destination = pdfView.currentDestination
        let oldPage = destination?.page
        let oldIndex = oldPage.flatMap { pdfView.document?.index(for: $0) }
        // A pinch can leave autoScales on, so only the actual scale tells if the user zoomed.
        let scale = pdfView.scaleFactor
        let keepsAuto = pdfView.document == nil
            || (pdfView.autoScales && abs(scale - pdfView.scaleFactorForSizeToFit) < 0.01)
        let position = scrollPosition()

        pdfView.document = document
        if keepsAuto {
            pdfView.autoScales = true
        } else {
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
        }
        pdfView.layoutDocumentView()
        if let oldIndex, let point = destination?.point, document.pageCount > 0,
           let page = document.page(at: min(oldIndex, document.pageCount - 1)) {
            pdfView.go(to: PDFDestination(page: page, at: point))
        }
        if let position {
            restoreScrollPosition(position)
            // PDFKit may finish laying out the new document a moment later.
            DispatchQueue.main.async { [weak self] in self?.restoreScrollPosition(position) }
        }
        pageChanged()
    }

    /// Measured from the document's top, which stays put when pages are added at the end.
    private func scrollPosition() -> (x: CGFloat, fromTop: CGFloat)? {
        guard pdfView.document != nil, let document = pdfView.documentView,
              let clip = document.enclosingScrollView?.contentView else { return nil }
        let bounds = clip.bounds
        return (bounds.origin.x, document.isFlipped ? bounds.origin.y : document.bounds.height - bounds.height - bounds.origin.y)
    }

    private func restoreScrollPosition(_ position: (x: CGFloat, fromTop: CGFloat)) {
        guard let document = pdfView.documentView, let scroll = document.enclosingScrollView else { return }
        let clip = scroll.contentView
        let y = document.isFlipped ? position.fromTop : document.bounds.height - clip.bounds.height - position.fromTop
        clip.scroll(to: NSPoint(x: position.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

// MARK: - Split view

/// The dividers are drawn one point thin, like in Apple's apps, but respond to
/// the mouse a few points to each side so they are easy to grab.
final class EasyGrabSplitViewController: NSSplitViewController {
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                   forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return splitView.isVertical ? rect.insetBy(dx: -4, dy: 0) : rect.insetBy(dx: 0, dy: -4)
    }
}

// MARK: - Project window

final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let root: URL
    var onClose: (() -> Void)?

    private let compiler = Compiler()
    let sidebar = SidebarViewController()
    private let leftEditor = EditorViewController()
    private let rightEditor = EditorViewController()
    private lazy var rightPane = RightPaneViewController(pdf: pdfPane, editor: rightEditor)
    private enum TabColumn { case left, right }
    /// The right column only counts as active while it shows a file, not the PDF.
    private var activeColumn = TabColumn.left
    var editor: EditorViewController { activeColumn == .right ? rightEditor : leftEditor }
    let citationIndex = CitationIndex()
    let history: VersionHistory
    var historySheet: HistorySheetController?
    private var watcher: ProjectWatcher?
    private var isSyncing = false
    let symbols = ProjectSymbols()
    private let quickOpen = QuickOpenController()
    let paperSearch = PaperSearchController()
    private var openTabs: [URL] = []
    private var rightTabs: [URL] = []
    private var activeTabs: [URL] { activeColumn == .right ? rightTabs : openTabs }
    private var pdfItem: NSSplitViewItem!
    private var isFocusMode = false
    private var focusRestoresSidebar = false
    private var focusRestoresLog = false
    var lastZoteroSync: Date?
    var zoteroBusy = false
    private var sidebarItem: NSSplitViewItem!
    private var indexTimer: Timer?
    private var lastResult: CompileResult?
    private var lastCompiledStem: String?
    private var lastCompileTarget: URL?
    let pdfCompiler = Compiler()
    var pdfBaseline: [String: Date] = [:]
    var pdfQueue: [URL] = []
    var isExportingPDF = false
    var pdfExportWaiters: [() -> Void] = []
    private var pdfTimer: Timer?
    private var errorsByFile: [String: [(line: Int, message: String)]] = [:]
    private let log = LogViewController()
    private let pdfPane = PDFPaneViewController()
    private let mainSplit = EasyGrabSplitViewController()
    private let centerSplit = EasyGrabSplitViewController()
    var gitBusy = false
    var isExportingImage = false
    private static let splitAutosaveName = "WalrasMainSplit"
    private var logItem: NSSplitViewItem!
    private var claudeItem: NSSplitViewItem!
    private let claude = ClaudePanelViewController()
    private var jevonsItem: NSSplitViewItem!
    private var didOpenJevons = false
    private let jevonsNotes = JevonsNotesViewController()
    private var focusRestoresClaude = false
    private var didOpenClaude = false

    private var bar: WindowBar!
    private var rootController: RootViewController!

    var buffers: [String: TextBuffer] = [:]
    private var leftShown: URL?
    private var rightShown: URL?
    private var shownURL: URL? {
        get { activeColumn == .right ? rightShown : leftShown }
        set {
            if activeColumn == .right { rightShown = newValue } else { leftShown = newValue }
        }
    }
    var currentFile: URL? { shownURL }
    private(set) var mainFile: URL?
    private var pdfData: Data?
    private var recompileQueued = false
    private var autosaveTimer: Timer?
    private var didClose = false

    var defaultsKey: String { "project:" + root.standardizedFileURL.path }

    var engine: Engine {
        get {
            let raw = (UserDefaults.standard.dictionary(forKey: defaultsKey)?["engine"] as? String) ?? ""
            return Engine(rawValue: raw) ?? .pdflatex
        }
        set { storeSetting("engine", newValue.rawValue) }
    }

    func storeSetting(_ key: String, _ value: String) {
        var settings = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        settings[key] = value
        UserDefaults.standard.set(settings, forKey: defaultsKey)
    }

    init(root: URL, requestedMain: URL?) {
        self.root = root
        history = VersionHistory(root: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 480)
        window.title = root.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = EditorTheme.current.bar
        super.init(window: window)
        window.delegate = self

        sidebar.project = self
        buildLayout()

        window.center()
        let hadFrame = window.setFrameUsingName("ProjectWindow")
        window.setFrameAutosaveName("ProjectWindow")
        if !hadFrame { window.center() }

        let columns: [(column: TabColumn, editor: EditorViewController)] = [(.left, leftEditor), (.right, rightEditor)]
        for (column, columnEditor) in columns {
            columnEditor.onUserEdit = { [weak self] in
                self?.scheduleAutosave()
                self?.scheduleIndexRefresh()
            }
            columnEditor.citationIndex = citationIndex
            columnEditor.onCitationClicked = { [weak self] key in self?.showCitationNotes(key: key) }
            columnEditor.onCitationAccepted = { [weak self] key in self?.addFromJevons(key: key) }
            columnEditor.onIncompleteCitation = { [weak self] key, finish in
                guard let paper = JevonsLibrary.shared.papers.first(where: { $0.citeKey == key }) else { return finish(key) }
                self?.completeJevonsPaper(paper, keepKey: false, citeAnyway: true, finish: finish)
            }
            columnEditor.symbols = symbols
            columnEditor.fileItems = { [weak self] kind, query in self?.fileCompletions(kind, query: query) ?? [] }
            columnEditor.onEscape = { [weak self] in self?.toggleFocusMode(nil) }
            columnEditor.onPasteImage = { [weak self] pasteboard in self?.latexForPastedImage(pasteboard) }
            columnEditor.onFocused = { [weak self] in self?.activate(column) }
            columnEditor.onSourceClick = { [weak self, weak columnEditor] line in
                if let file = columnEditor?.current?.url { self?.jumpToPDF(file: file, line: line) }
            }
        }
        rightEditor.hideOwnTabBar()
        rightEditor.showNothing()
        configureTabBar(leftEditor.tabBar, column: .left, moveTitle: L("Mover a la columna del PDF", "Move to PDF Column"))
        configureTabBar(rightPane.tabBar, column: .right, moveTitle: L("Mover a la columna del código", "Move to Code Column"))
        (leftEditor.view as? TabDropView)?.canAccept = { [weak self] url in self?.isTab(url, in: .right) ?? false }
        (leftEditor.view as? TabDropView)?.onDrop = { [weak self] url in self?.moveTabToOtherColumn(url) }
        (rightPane.view as? TabDropView)?.canAccept = { [weak self] url in self?.isTab(url, in: .left) ?? false }
        (rightPane.view as? TabDropView)?.onDrop = { [weak self] url in self?.moveTabToOtherColumn(url) }
        quickOpen.onOpen = { [weak self] url in
            self?.open(url)
            self?.editor.focus()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)),
                                               name: .editorThemeChanged, object: nil)
        log.onSelectIssue = { [weak self] issue in self?.reveal(issue) }
        _ = pdfPane.view
        pdfPane.pdfView.onCommandClick = { [weak self] page, x, y, word in
            self?.jumpToSource(page: page, x: x, y: y, word: word)
        }
        log.onCopyErrors = { [weak self] in self?.copyErrors(nil) }
        log.onCopyFullLog = { [weak self] in self?.copyFullLog(nil) }

        resolveMainFile(requested: requestedMain)
        sidebar.reload(selecting: mainFile)
        restoreTabs()
        if let mainFile { open(mainFile) } else { editor.showNothing() }
        refreshTabs()
        citationIndex.reload(root: root)
        symbols.reload(root: root)
        applySpelling()
        applyInitialSplit()
        leftEditor.tabBar.setLeavesRoomForLogo(sidebarItem.isCollapsed)
        syncZoteroIfConfigured()
        watcher = ProjectWatcher(root: root) { [weak self] in self?.projectFolderChanged() }
        pdfBaseline = sourceSnapshot()
        pdfTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.exportChangedDocuments()
        }
        if mainFile != nil {
            DispatchQueue.main.async { [weak self] in self?.recompile(nil) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Runs when anything in the folder changes, including Walras's own saves, which
    /// count as no change because they match what the buffer already knows.
    private func projectFolderChanged() {
        guard !isSyncing, !didClose, NSApp.modalWindow == nil, window?.attachedSheet == nil else { return }
        isSyncing = true
        syncWithDisk()
        isSyncing = false
    }

    private func buildLayout() {
        let mainView = ThemedSplitView()
        mainView.isVertical = true
        mainSplit.splitView = mainView
        let centerView = ThemedSplitView()
        centerView.isVertical = false
        centerSplit.splitView = centerView

        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true

        let editorItem = NSSplitViewItem(viewController: leftEditor)
        editorItem.minimumThickness = 160
        logItem = NSSplitViewItem(viewController: log)
        logItem.canCollapse = true
        logItem.minimumThickness = 80
        logItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        logItem.isCollapsed = true
        claudeItem = NSSplitViewItem(viewController: claude)
        claudeItem.canCollapse = true
        claudeItem.minimumThickness = 150
        claudeItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 255)
        claudeItem.isCollapsed = true
        centerSplit.addSplitViewItem(editorItem)
        centerSplit.addSplitViewItem(claudeItem)
        jevonsItem = NSSplitViewItem(viewController: jevonsNotes)
        jevonsItem.canCollapse = true
        jevonsItem.minimumThickness = 120
        jevonsItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 254)
        jevonsItem.isCollapsed = true
        jevonsNotes.entries = { [weak self] in self?.citationIndex.entries ?? [] }
        jevonsNotes.onPrevious = { [weak self] in self?.moveCitation(by: -1) }
        jevonsNotes.onNext = { [weak self] in self?.moveCitation(by: 1) }
        jevonsNotes.onHide = { [weak self] in self?.hideJevonsRow() }
        jevonsNotes.isBibStale = { [weak self] key, paper in self?.bibEntryIsStale(key: key, paper: paper) ?? false }
        jevonsNotes.onUpdateBib = { [weak self] in self?.updateCitedEntry() }
        jevonsNotes.onComplete = { [weak self] in self?.completeCitedPaper() }
        jevonsNotes.onAdd = { [weak self] choosingPDF in
            guard let self, let key = self.jevonsNotes.currentKey else { return }
            self.addCitationToJevons(key: key, choosingPDF: choosingPDF) { self.jevonsNotes.showAdding() }
        }
        centerSplit.addSplitViewItem(jevonsItem)
        centerSplit.addSplitViewItem(logItem)

        claude.projectRoot = root
        claude.contextProvider = { [weak self] in self?.claudeContext() ?? "" }
        claude.applyEdit = { [weak self] edit in self?.applyClaudeEdit(edit) ?? false }

        let centerItem = NSSplitViewItem(viewController: centerSplit)
        centerItem.minimumThickness = 300
        pdfItem = NSSplitViewItem(viewController: rightPane)
        pdfItem.minimumThickness = 280
        // Above the code column's default, so that the code takes any change in available width.
        pdfItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        mainSplit.addSplitViewItem(sidebarItem)
        mainSplit.addSplitViewItem(centerItem)
        mainSplit.addSplitViewItem(pdfItem)
        mainSplit.splitView.autosaveName = Self.splitAutosaveName
        bar = WindowBar()
        rootController = RootViewController(bar: bar, content: mainSplit)
        rootController.onLogoClick = { [weak self] in self?.toggleSidebarAction(nil) }
        NotificationCenter.default.addObserver(self, selector: #selector(mainColumnsResized(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification,
                                               object: mainSplit.splitView)
        window?.contentViewController = rootController
        updateSubtitle()
    }

    private func applyInitialSplit() {
        guard let window else { return }
        // After the first run, keep the column widths the user chose.
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.splitAutosaveName)") != nil { return }
        window.layoutIfNeeded()
        let width = mainSplit.splitView.bounds.width
        let sidebarWidth: CGFloat = 190
        mainSplit.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        mainSplit.splitView.setPosition(sidebarWidth + (width - sidebarWidth) / 2, ofDividerAt: 1)
    }

    private func updateSubtitle() {
        bar?.setTitle(project: root.lastPathComponent)
    }

    func relativePath(_ url: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    // MARK: - Bar and window

    @objc func formatBold(_ sender: Any?) { editor.wrapSelection(withCommand: "textbf") }
    @objc func formatItalic(_ sender: Any?) { editor.wrapSelection(withCommand: "textit") }

    @objc func toggleClaudePanel(_ sender: Any?) {
        let willOpen = claudeItem.isCollapsed
        if willOpen, !didOpenClaude {
            didOpenClaude = true
            claude.loadConversation()
            claudeItem.isCollapsed = false
            centerSplit.splitView.layoutSubtreeIfNeeded()
            centerSplit.splitView.setPosition(centerSplit.splitView.bounds.height * 0.55, ofDividerAt: 0)
        } else {
            claudeItem.animator().isCollapsed = !willOpen
        }
        if willOpen {
            claude.focusInput()
        } else {
            editor.focus()
        }
    }

    /// ⌘-click on a citation: the row with what Jevons has on that paper.
    private func showCitationNotes(key: String) {
        openJevonsRow()
        jevonsNotes.show(key: key)
        updateCitationPosition()
    }

    private func openJevonsRow() {
        guard jevonsItem.isCollapsed else { return }
        if !didOpenJevons {
            // The row starts at a size where the notes can be read; from then on it keeps what you drag it to.
            didOpenJevons = true
            jevonsItem.minimumThickness = centerSplit.splitView.bounds.height * 0.36
            jevonsItem.isCollapsed = false
            centerSplit.splitView.layoutSubtreeIfNeeded()
            jevonsItem.minimumThickness = 120
        } else {
            jevonsItem.isCollapsed = false
        }
    }

    private func updateCitationPosition() {
        let keys = editor.citedKeysInOrder().map(\.key)
        jevonsNotes.setPosition(index: jevonsNotes.currentKey.flatMap { keys.firstIndex(of: $0) }, count: keys.count)
    }

    /// The arrows: the next or previous paper this file cites, in the order it cites them.
    private func moveCitation(by step: Int) {
        let cited = editor.citedKeysInOrder()
        guard !cited.isEmpty else { return }
        let current = jevonsNotes.currentKey.flatMap { key in cited.firstIndex { $0.key == key } }
        let index: Int
        if let current {
            index = current + step
        } else {
            index = step > 0 ? 0 : cited.count - 1
        }
        guard cited.indices.contains(index) else { return }
        let target = cited[index]
        jevonsNotes.show(key: target.key)
        editor.reveal(location: target.location, length: target.length)
        updateCitationPosition()
    }

    private var citedPaper: (key: String, paper: JevonsPaper)? {
        guard let key = jevonsNotes.currentKey,
              let paper = JevonsLibrary.shared.paper(forCitation: key, entries: citationIndex.entries) else { return nil }
        return (key, paper)
    }

    /// From the row: the citation stays as it is, and its entry takes the data you confirm.
    private func completeCitedPaper() {
        guard let cited = citedPaper else { return }
        completeJevonsPaper(cited.paper, keepKey: true, citeAnyway: false) { [weak self] _ in self?.updateCitedEntry() }
    }

    private func updateCitedEntry() {
        guard let cited = citedPaper else { return }
        updateBibEntry(key: cited.key, paper: cited.paper)
        jevonsNotes.refresh()
    }

    private func hideJevonsRow() {
        jevonsItem.isCollapsed = true
        editor.focus()
    }

    @objc func openCitedPaperInJevons(_ sender: Any?) {
        guard let key = editor.citationKeyAtCaret() else {
            setStatus(L("Poné el cursor sobre un \\cite{}", "Put the caret on a \\cite{}"), .secondaryLabelColor)
            return
        }
        guard let paper = JevonsLibrary.shared.paper(forCitation: key, entries: citationIndex.entries),
              let url = JevonsLibrary.link(key: paper.citeKey) else {
            setStatus(L("\(key) no está en Jevons", "\(key) isn't in Jevons"), .secondaryLabelColor)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func refreshJevonsNotes() {
        JevonsLibrary.shared.refresh()
        jevonsNotes.refresh()
    }

    func lastCompileErrorsForClaude() -> String {
        guard let result = lastResult else { return "" }
        return result.issues.prefix(5).map { issue in
            if let file = issue.file, let line = issue.line { return "\(file):\(line): \(issue.message)" }
            return issue.message
        }.joined(separator: "\n")
    }

    @objc private func mainColumnsResized(_ notification: Notification) {
        leftEditor.tabBar.setLeavesRoomForLogo(sidebarItem.isCollapsed)
    }

    @objc func toggleSidebarAction(_ sender: Any?) {
        let pdfWidth = rightPane.view.frame.width
        NSAnimationContext.runAnimationGroup({ _ in
            sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
        }, completionHandler: { [weak self] in
            // Opening the sidebar can squeeze the PDF when the code is at its minimum width.
            guard let self, !self.pdfItem.isCollapsed else { return }
            let split = self.mainSplit.splitView
            split.setPosition(split.bounds.width - pdfWidth - split.dividerThickness, ofDividerAt: 1)
        })
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(downloadPDF(_:)):
            return pdfData != nil
        case #selector(stopCompile(_:)):
            return compiler.isRunning
        case #selector(pushToGitHub(_:)):
            return !gitBusy
        case #selector(copyErrors(_:)), #selector(copyFullLog(_:)):
            return lastResult != nil
        case #selector(setTheme(_:)):
            item.state = EditorTheme.all[item.tag].id == EditorTheme.current.id ? .on : .off
            return true
        case #selector(setSpellLanguage(_:)):
            item.state = Self.spellLanguages[item.tag] == spellLanguage ? .on : .off
            return true
        case #selector(showVersionHistory(_:)):
            return editor.current != nil
        case #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(copySelectionAsImage(_:)), #selector(copySelectionAsDarkImage(_:)):
            return editor.canFormatText
        case #selector(toggleClaudePanel(_:)):
            item.state = claudeItem.isCollapsed ? .off : .on
            return true
        case #selector(toggleFocusMode(_:)):
            item.state = isFocusMode ? .on : .off
            return true
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return activeTabs.count > 1
        case #selector(toggleCompileOnSave(_:)):
            item.state = Self.compileOnSave ? .on : .off
            return true
        case #selector(setEngine(_:)):
            item.state = Engine.allCases[item.tag] == engine ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - Opening files

    private func resolveMainFile(requested: URL?) {
        if let requested {
            mainFile = requested
            storeSetting("main", relativePath(requested))
            return
        }
        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey)?["main"] as? String {
            let url = root.appendingPathComponent(stored)
            if FileManager.default.fileExists(atPath: url.path) {
                mainFile = url
                return
            }
        }
        mainFile = detectMainFile()
    }

    private func detectMainFile() -> URL? {
        let fm = FileManager.default
        let conventional = root.appendingPathComponent("main.tex")
        if fm.fileExists(atPath: conventional.path) { return conventional }

        var candidates: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "tex" {
                candidates.append(url)
            }
        }
        candidates.sort { $0.pathComponents.count < $1.pathComponents.count }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               String(decoding: data, as: UTF8.self).contains("\\documentclass") {
                return url
            }
        }
        return candidates.first
    }

    func setMainFile(_ url: URL) {
        mainFile = url
        storeSetting("main", relativePath(url))
        sidebar.reload(selecting: shownURL)
    }

    /// A file opens on the left unless its tab already lives on the right.
    func open(_ url: URL) {
        open(url, in: isTab(url, in: .right) ? .right : .left)
    }

    private func open(_ url: URL, in column: TabColumn) {
        saveAll(interactive: false)
        if column != activeColumn { editor.hideCompletion() }
        activeColumn = column
        if column == .right { rightPane.show(pdf: false) }
        let key = url.standardizedFileURL.path
        if ProjectFiles.isText(url) {
            let buffer: TextBuffer
            if let existing = buffers[key] {
                buffer = existing
            } else if let loaded = TextBuffer(url: url, font: editor.font) {
                buffers[key] = loaded
                buffer = loaded
                applyErrorMarks(to: loaded)
                history.record(url, minimumInterval: 300)
            } else {
                editor.showPreview(of: url)
                finishOpening(url)
                return
            }
            editor.show(buffer)
        } else {
            editor.showPreview(of: url)
        }
        finishOpening(url)
    }

    private func finishOpening(_ url: URL) {
        shownURL = url
        sidebar.select(url)
        updateSubtitle()
        if !isTab(url, in: activeColumn) {
            if activeColumn == .right { rightTabs.append(url) } else { openTabs.append(url) }
        }
        refreshTabs()
    }

    private func isTab(_ url: URL, in column: TabColumn) -> Bool {
        let path = url.standardizedFileURL.path
        return (column == .right ? rightTabs : openTabs).contains { $0.standardizedFileURL.path == path }
    }

    private func activate(_ column: TabColumn) {
        guard column != activeColumn, column == .left || rightShown != nil else { return }
        editor.hideCompletion()
        activeColumn = column
        if let shownURL { sidebar.select(shownURL) }
    }

    private func configureTabBar(_ bar: EditorTabBar, column: TabColumn, moveTitle: String) {
        bar.moveTitle = moveTitle
        bar.onSelect = { [weak self] url in
            guard let self else { return }
            if url == EditorTabBar.pdfURL {
                self.showPDFTab()
            } else {
                self.open(url, in: column)
                self.editor.focus()
            }
        }
        bar.onClose = { [weak self] url in self?.closeTab(url) }
        bar.onCloseOthers = { [weak self] url in self?.closeOtherTabs(keeping: url, in: column) }
        bar.onMove = { [weak self] url in self?.moveTabToOtherColumn(url) }
    }

    private func showPDFTab() {
        rightEditor.showNothing()
        rightShown = nil
        rightPane.show(pdf: true)
        if activeColumn == .right {
            activeColumn = .left
            if let leftShown { sidebar.select(leftShown) }
            leftEditor.focus()
        }
        refreshTabs()
    }

    private func closeOtherTabs(keeping kept: URL, in column: TabColumn) {
        if kept == EditorTabBar.pdfURL {
            showPDFTab()
        } else {
            open(kept, in: column)
        }
        let path = kept.standardizedFileURL.path
        for tab in column == .right ? rightTabs : openTabs where tab.standardizedFileURL.path != path {
            closeTab(tab)
        }
    }

    /// A file is only ever in one column, since a text storage has one editing position.
    /// The column it leaves lets go of it first.
    private func moveTabToOtherColumn(_ url: URL) {
        let path = url.standardizedFileURL.path
        if isTab(url, in: .left) {
            let index = openTabs.firstIndex { $0.standardizedFileURL.path == path }!
            openTabs.remove(at: index)
            if leftShown?.standardizedFileURL.path == path {
                if openTabs.isEmpty {
                    leftShown = nil
                    leftEditor.showNothing()
                } else {
                    open(openTabs[min(index, openTabs.count - 1)], in: .left)
                }
            }
            rightTabs.append(url)
            open(url, in: .right)
        } else if isTab(url, in: .right) {
            let index = rightTabs.firstIndex { $0.standardizedFileURL.path == path }!
            rightTabs.remove(at: index)
            if rightShown?.standardizedFileURL.path == path {
                if rightTabs.isEmpty {
                    showPDFTab()
                } else {
                    open(rightTabs[min(index, rightTabs.count - 1)], in: .right)
                }
            }
            openTabs.append(url)
            open(url, in: .left)
        } else {
            return
        }
        editor.focus()
    }

    // MARK: - Tabs

    private func refreshTabs() {
        let names = (openTabs + rightTabs).map(\.lastPathComponent)
        let describe = { (url: URL) -> (url: URL, title: String, tooltip: String) in
            let relative = self.relativePath(url)
            let isRepeated = names.filter { $0 == url.lastPathComponent }.count > 1
            return (url, isRepeated ? relative : url.lastPathComponent, relative)
        }
        let errorPaths = Set(errorsByFile.keys)
        leftEditor.tabBar.display(tabs: openTabs.map(describe), selected: leftShown, errorPaths: errorPaths)
        storeSetting("tabs", openTabs.map { relativePath($0) }.joined(separator: "\n"))

        let pdfTab = (url: EditorTabBar.pdfURL, title: "PDF", tooltip: "PDF")
        rightPane.tabBar.display(tabs: [pdfTab] + rightTabs.map(describe), selected: rightShown ?? EditorTabBar.pdfURL, errorPaths: errorPaths)
        rightPane.setTabsVisible(!rightTabs.isEmpty)
        storeSetting("rightTabs", rightTabs.map { relativePath($0) }.joined(separator: "\n"))
    }

    private func restoreTabs() {
        func saved(_ key: String) -> [URL] {
            let list = (UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? String) ?? ""
            return list.split(separator: "\n").map { root.appendingPathComponent(String($0)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        // The main file opens at launch and belongs on the left, leaving the PDF in view.
        let mainPath = mainFile?.standardizedFileURL.path
        rightTabs = saved("rightTabs").filter { $0.standardizedFileURL.path != mainPath }
        let rightPaths = Set(rightTabs.map { $0.standardizedFileURL.path })
        openTabs = saved("tabs").filter { !rightPaths.contains($0.standardizedFileURL.path) }
    }

    func closeTab(_ url: URL) {
        saveAll(interactive: true)
        let path = url.standardizedFileURL.path
        let previousColumn = activeColumn
        if let index = openTabs.firstIndex(where: { $0.standardizedFileURL.path == path }) {
            openTabs.remove(at: index)
            if leftShown?.standardizedFileURL.path == path {
                if openTabs.isEmpty {
                    leftShown = nil
                    leftEditor.showNothing()
                } else {
                    open(openTabs[min(index, openTabs.count - 1)], in: .left)
                }
            }
        } else if let index = rightTabs.firstIndex(where: { $0.standardizedFileURL.path == path }) {
            rightTabs.remove(at: index)
            if rightShown?.standardizedFileURL.path == path {
                if rightTabs.isEmpty {
                    showPDFTab()
                } else {
                    open(rightTabs[min(index, rightTabs.count - 1)], in: .right)
                }
            }
        } else {
            return
        }
        if buffers[path]?.dirty == false { buffers[path] = nil }
        activate(previousColumn)
        refreshTabs()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        if let shownURL {
            closeTab(shownURL)
        } else {
            window?.performClose(sender)
        }
    }

    private func moveTab(by delta: Int) {
        let tabs = activeTabs
        guard tabs.count > 1, let shownURL else { return }
        let path = shownURL.standardizedFileURL.path
        guard let index = tabs.firstIndex(where: { $0.standardizedFileURL.path == path }) else { return }
        open(tabs[(index + delta + tabs.count) % tabs.count], in: activeColumn)
        editor.focus()
    }

    @objc func nextTab(_ sender: Any?) { moveTab(by: 1) }
    @objc func previousTab(_ sender: Any?) { moveTab(by: -1) }

    // MARK: - Quick open

    @objc func showQuickOpen(_ sender: Any?) {
        guard let window else { return }
        sidebar.reload(selecting: shownURL)
        let tabPaths = Set((openTabs + rightTabs).map { $0.standardizedFileURL.path })
        let files = openTabs + rightTabs + sidebar.projectFiles.filter { !tabPaths.contains($0.standardizedFileURL.path) }
        quickOpen.show(files: files.map { (url: $0, path: relativePath($0)) }, in: window)
    }

    // MARK: - Focus mode

    @objc func toggleFocusMode(_ sender: Any?) {
        isFocusMode.toggle()
        if isFocusMode {
            focusRestoresSidebar = !sidebarItem.isCollapsed
            focusRestoresLog = !logItem.isCollapsed
            focusRestoresClaude = !claudeItem.isCollapsed
            claudeItem.isCollapsed = true
            pdfItem.canCollapse = true
            sidebarItem.isCollapsed = true
            logItem.isCollapsed = true
            pdfItem.isCollapsed = true
            rootController.setBarHidden(true)
        } else {
            rootController.setBarHidden(false)
            pdfItem.isCollapsed = false
            pdfItem.canCollapse = false
            sidebarItem.isCollapsed = !focusRestoresSidebar
            logItem.isCollapsed = !focusRestoresLog
            claudeItem.isCollapsed = !focusRestoresClaude
        }
        // Focus mode hides the right column.
        if isFocusMode { activate(.left) }
        leftEditor.setFocusMode(isFocusMode)
        editor.focus()
    }

    // MARK: - Theme and spelling

    @objc func setTheme(_ sender: NSMenuItem) {
        guard EditorTheme.all.indices.contains(sender.tag) else { return }
        EditorTheme.current = EditorTheme.all[sender.tag]
    }

    @objc private func themeChanged(_ notification: Notification) {
        leftEditor.applyTheme(buffers: Array(buffers.values))
        rightEditor.applyTheme(buffers: [])
        refreshTabs()
        window?.backgroundColor = EditorTheme.current.bar
        bar.refreshColors()
        sidebar.applyTheme()
        log.applyTheme()
        claude.applyTheme()
        pdfPane.applyTheme()
        mainSplit.splitView.needsDisplay = true
        centerSplit.splitView.needsDisplay = true
    }

    private static let spellLanguages = ["", "es", "en"]

    private var spellLanguage: String {
        (UserDefaults.standard.dictionary(forKey: defaultsKey)?["spell"] as? String) ?? ""
    }

    @objc func setSpellLanguage(_ sender: NSMenuItem) {
        guard Self.spellLanguages.indices.contains(sender.tag) else { return }
        storeSetting("spell", Self.spellLanguages[sender.tag])
        applySpelling()
    }

    /// The system's spell checker has a single language per app, so each window
    /// sets its own when it comes to the front.
    private func applySpelling() {
        let language = spellLanguage
        _ = rightEditor.setSpelling(language: language.isEmpty ? nil : language)
        if !leftEditor.setSpelling(language: language.isEmpty ? nil : language) {
            setStatus(L("Ese idioma no está instalado en esta Mac", "That language isn't installed on this Mac"), .secondaryLabelColor)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applySpelling()
    }

    func openLocation(_ url: URL, line: Int, column: Int, length: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        open(url)
        editor.go(toLine: line, column: column, length: length)
    }

    private func jumpToSource(page: Int, x: Double, y: Double, word: String?) {
        guard let stem = lastCompiledStem else { return }
        let directory = lastResult?.workingDirectory ?? compileDirectory
        compiler.sourceLocation(page: page, x: x, y: y, stem: stem) { [weak self] found in
            guard let self else { return }
            guard let found else {
                self.setStatus(L("No encontré ese punto en el código", "Couldn't find that point in the code"), .secondaryLabelColor)
                return
            }
            let url = found.file.hasPrefix("/") ? URL(fileURLWithPath: found.file).standardizedFileURL
                                                : directory.appendingPathComponent(found.file).standardizedFileURL
            guard url.path.hasPrefix(self.root.standardizedFileURL.path),
                  FileManager.default.fileExists(atPath: url.path) else {
                self.setStatus(L("Ese punto viene de un paquete, no de tu código", "That point comes from a package, not your code"), .secondaryLabelColor)
                return
            }
            self.open(url)
            self.editor.go(toLine: found.line, near: word)
        }
    }

    private func jumpToPDF(file: URL, line: Int) {
        guard let stem = lastCompiledStem else {
            setStatus(L("Compilá para poder ir al PDF", "Compile to be able to go to the PDF"), .secondaryLabelColor)
            return
        }
        saveAll(interactive: false)
        compiler.pdfLocation(file: file, line: line, stem: stem) { [weak self] found in
            guard let self else { return }
            guard let found else {
                self.setStatus(L("Esa línea no está en el PDF actual; probá recompilar", "That line isn't in the current PDF; try recompiling"), .secondaryLabelColor)
                return
            }
            if self.rightShown != nil { self.showPDFTab() }
            self.pdfPane.reveal(page: found.page, left: found.left, bottom: found.bottom, width: found.width, height: found.height)
        }
    }

    func openBufferTexts() -> [String: String] {
        buffers.mapValues { $0.storage.string }
    }

    // MARK: - Sidebar tabs

    private func showSidebarTab(_ tab: SidebarTab) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebar.show(tab)
    }

    @objc func showFilesTab(_ sender: Any?) { showSidebarTab(.files) }
    @objc func showIndexTab(_ sender: Any?) { showSidebarTab(.index) }
    @objc func searchInProject(_ sender: Any?) { showSidebarTab(.search) }

    private func scheduleIndexRefresh() {
        guard sidebar.isShowingIndex else { return }
        indexTimer?.invalidate()
        indexTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.refreshIndexNow()
        }
    }

    func refreshIndexNow() {
        guard let main = compileTarget() else {
            sidebar.indexPane.display([])
            return
        }
        let open = buffers
        let items = DocumentOutline.build(main: main) { url in
            if let buffer = open[url.standardizedFileURL.path] { return buffer.storage.string }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        sidebar.indexPane.display(items)
    }

    // MARK: - Pasting images

    private static let directImageTypes: Set<String> = ["png", "jpg", "jpeg", "pdf"]
    private static let convertibleImageTypes: Set<String> = ["tif", "tiff", "heic", "gif", "bmp", "webp"]

    /// Saves the clipboard's image into the project and returns the LaTeX that
    /// shows it, or nil so that text is pasted as usual.
    private func latexForPastedImage(_ pasteboard: NSPasteboard) -> String? {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let imageURLs = fileURLs.filter {
            let ext = $0.pathExtension.lowercased()
            return Self.directImageTypes.contains(ext) || Self.convertibleImageTypes.contains(ext)
        }
        var saved: [URL] = []
        do {
            if !imageURLs.isEmpty {
                for source in imageURLs {
                    let folder = try figuresDirectory()
                    if Self.directImageTypes.contains(source.pathExtension.lowercased()) {
                        let destination = ProjectFiles.uniqueDestination(for: source.lastPathComponent, in: folder)
                        try FileManager.default.copyItem(at: source, to: destination)
                        saved.append(destination)
                    } else if let tiff = NSImage(contentsOf: source)?.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let name = source.deletingPathExtension().lastPathComponent + ".png"
                        let destination = ProjectFiles.uniqueDestination(for: name, in: folder)
                        try png.write(to: destination)
                        saved.append(destination)
                    }
                }
            } else {
                // Apps like Excel copy text and a picture together: there, the text wins.
                guard pasteboard.string(forType: .string) == nil else { return nil }
                var pngData = pasteboard.data(forType: .png)
                if pngData == nil, let tiff = pasteboard.data(forType: .tiff) {
                    pngData = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                }
                guard let png = pngData else { return nil }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let folder = try figuresDirectory()
                let destination = ProjectFiles.uniqueDestination(
                    for: L("pegado-\(formatter.string(from: Date())).png", "pasted-\(formatter.string(from: Date())).png"), in: folder)
                try png.write(to: destination)
                saved.append(destination)
            }
        } catch {
            NSAlert(error: error).runModal()
            return ""
        }
        guard !saved.isEmpty else { return nil }
        sidebar.reload(selecting: shownURL)
        return saved.map { "\\includegraphics[width=0.8\\textwidth]{\(pathFromCompileDirectory($0))}" }
            .joined(separator: "\n")
    }

    private var compileDirectory: URL {
        compileTarget()?.deletingLastPathComponent() ?? root
    }

    private func figuresDirectory() throws -> URL {
        let fm = FileManager.default
        for name in ["figuras", "figures", "imagenes", "images", "img"] {
            var isDirectory: ObjCBool = false
            let candidate = compileDirectory.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        let folder = compileDirectory.appendingPathComponent(L("figuras", "figures"), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func pathFromCompileDirectory(_ url: URL) -> String {
        let base = compileDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    // MARK: - Copying errors

    private func copyToClipboard(_ text: String, confirmation: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        setStatus(confirmation, .secondaryLabelColor)
    }

    private func sourceLine(for issue: CompileIssue) -> String? {
        guard let file = issue.file, let line = issue.line, line > 0 else { return nil }
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file)
                                      : compileDirectory.appendingPathComponent(file).standardizedFileURL
        let text: String
        if let buffer = buffers[url.standardizedFileURL.path] {
            text = buffer.storage.string
        } else if let data = try? Data(contentsOf: url) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            return nil
        }
        var lines: [String] = []
        text.enumerateLines { current, stop in
            lines.append(current)
            if lines.count == line { stop = true }
        }
        return lines.count == line ? lines[line - 1] : nil
    }

    @objc func copyErrors(_ sender: Any?) {
        guard let result = lastResult else { return }
        guard !result.issues.isEmpty else {
            copyFullLog(sender)
            return
        }
        var parts = [L("Compilé un documento LaTeX con \(engine.title) y dio estos errores. Archivo principal: \((lastCompileTarget ?? mainFile)?.lastPathComponent ?? "desconocido").", "I compiled a LaTeX document with \(engine.title) and got these errors. Main file: \((lastCompileTarget ?? mainFile)?.lastPathComponent ?? "unknown").")]
        for (index, issue) in result.issues.enumerated() {
            var block = "Error \(index + 1)"
            if let file = issue.file, let line = issue.line { block += L(" en \(file), línea \(line)", " in \(file), line \(line)") }
            block += ":\n\(issue.message)"
            if let source = sourceLine(for: issue) { block += L("\n\nLínea del código:\n\(source)", "\n\nLine of code:\n\(source)") }
            if !issue.context.isEmpty { block += L("\n\nDetalle del log:\n\(issue.context)", "\n\nLog detail:\n\(issue.context)") }
            parts.append(block)
        }
        let count = result.issues.count
        copyToClipboard(parts.joined(separator: "\n\n"),
                        confirmation: count == 1 ? L("Error copiado", "Error copied") : L("\(count) errores copiados", "\(count) errors copied"))
    }

    @objc func copyFullLog(_ sender: Any?) {
        guard let result = lastResult else { return }
        copyToClipboard(result.log.isEmpty ? result.output : result.log, confirmation: L("Log completo copiado", "Full log copied"))
    }

    // MARK: - Compile on save

    private static var compileOnSave: Bool {
        UserDefaults.standard.object(forKey: "compileOnSave") as? Bool ?? true
    }

    @objc func toggleCompileOnSave(_ sender: Any?) {
        UserDefaults.standard.set(!Self.compileOnSave, forKey: "compileOnSave")
    }

    // MARK: - Alerts

    func showAlert(_ message: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func reveal(_ issue: CompileIssue) {
        guard let file = issue.file else { return }
        let base = (lastCompileTarget ?? mainFile ?? root.appendingPathComponent("x")).deletingLastPathComponent()
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file)
                                      : base.appendingPathComponent(file).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path),
              FileManager.default.fileExists(atPath: url.path) else { return }
        open(url)
        if let line = issue.line { editor.go(toLine: line) }
    }

    // MARK: - Saving

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.saveAll(interactive: false)
        }
    }

    /// Non-interactive saves skip any file that changed on disk behind our back;
    /// those wait for syncWithDisk or an explicit save to ask the user.
    func saveAll(interactive: Bool) {
        defer { JevonsCitations.schedule(root: root, entries: citationIndex.entries) }
        for buffer in buffers.values where buffer.dirty {
            if buffer.changedOnDisk {
                if !interactive { continue }
                if !confirmOverwrite(buffer) {
                    reload(buffer)
                    continue
                }
            }
            do {
                try buffer.write()
                history.record(buffer.url, minimumInterval: 300)
                let ext = buffer.url.pathExtension.lowercased()
                if ext == "bib" { citationIndex.reload(root: root) }
                if ["tex", "ltx", "sty", "cls"].contains(ext) { symbols.reload(root: root) }
            } catch {
                if interactive { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Keeps the on-screen text in the history before the file's new contents replace it.
    private func reload(_ buffer: TextBuffer) {
        if let data = buffer.storage.string.data(using: buffer.encoding, allowLossyConversion: true) {
            history.record(buffer.url, data: data)
        }
        buffer.reloadFromDisk(font: editor.font)
        errorsByFile[buffer.url.standardizedFileURL.path] = nil
        history.record(buffer.url)
        for columnEditor in [leftEditor, rightEditor] where columnEditor.current === buffer {
            columnEditor.refreshAfterReload()
        }
    }

    private func confirmOverwrite(_ buffer: TextBuffer) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("“\(buffer.url.lastPathComponent)” cambió fuera de Walras.", "“\(buffer.url.lastPathComponent)” changed outside Walras.")
        alert.informativeText = L("Tenés cambios sin guardar en este archivo. ¿Con qué versión te quedás?", "You have unsaved changes in this file. Which version do you want to keep?")
        alert.addButton(withTitle: L("Mantener la mía", "Keep Mine"))
        alert.addButton(withTitle: L("Usar la del disco", "Use the One on Disk"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Picks up edits made by other programs when the app comes back to the front.
    func syncWithDisk() {
        let fm = FileManager.default
        for (key, buffer) in buffers {
            guard fm.fileExists(atPath: buffer.url.path) else {
                buffers[key] = nil
                let path = buffer.url.standardizedFileURL.path
                openTabs.removeAll { $0.standardizedFileURL.path == path }
                rightTabs.removeAll { $0.standardizedFileURL.path == path }
                if leftShown?.standardizedFileURL.path == path {
                    leftEditor.showNothing()
                    leftShown = nil
                }
                if rightShown?.standardizedFileURL.path == path { showPDFTab() }
                refreshTabs()
                continue
            }
            guard buffer.changedOnDisk else { continue }
            if !buffer.dirty || !confirmOverwrite(buffer) {
                reload(buffer)
            } else {
                try? buffer.write()
            }
        }
        if let main = mainFile, !fm.fileExists(atPath: main.path) { mainFile = detectMainFile() }
        sidebar.reloadIfChanged(selecting: shownURL)
        citationIndex.reload(root: root)
        symbols.reload(root: root)
        if sidebar.isShowingIndex { refreshIndexNow() }
    }

    func prepareToClose() {
        autosaveTimer?.invalidate()
        pdfTimer?.invalidate()
        watcher?.stop()
        watcher = nil
        saveAll(interactive: true)
        for buffer in buffers.values { history.record(buffer.url) }
        compiler.dispose()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        prepareToClose()
        // Holds on to this controller until the last PDF is saved.
        finishPDFExports { [self] in pdfCompiler.dispose() }
        onClose?()
    }

    // MARK: - Compiling

    private static let documentClassPattern = try! NSRegularExpression(pattern: "(?m)^[ \\t]*\\\\documentclass")

    func isStandaloneDocument(_ url: URL) -> Bool {
        guard ["tex", "ltx"].contains(url.pathExtension.lowercased()) else { return false }
        guard let text = buffers[url.standardizedFileURL.path]?.storage.string
                ?? (try? Data(contentsOf: url)).map({ String(decoding: $0, as: UTF8.self) }) else { return false }
        return Self.documentClassPattern.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Which document to compile: the file in view if it is a whole document. A piece of one
    /// (a chapter, a .bib) belongs to the last compiled document if it sits under that one's
    /// folder, or else to the nearest document in the folders above it. The main file is the fallback.
    func compileTarget() -> URL? {
        if let currentFile { return document(containing: currentFile) }
        return lastCompileTarget.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? mainFile
    }

    func document(containing current: URL) -> URL? {
        let fm = FileManager.default
        let last = lastCompileTarget.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        if isStandaloneDocument(current) { return current }

        let rootPath = root.standardizedFileURL.path
        var folder = current.deletingLastPathComponent().standardizedFileURL
        if let last, (current.standardizedFileURL.path + "/").hasPrefix(last.deletingLastPathComponent().standardizedFileURL.path + "/") {
            return last
        }
        while folder.path == rootPath || folder.path.hasPrefix(rootPath + "/") {
            if let mainFile, mainFile.deletingLastPathComponent().standardizedFileURL.path == folder.path { return mainFile }
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            if let found = names.map({ folder.appendingPathComponent($0) }).first(where: isStandaloneDocument) { return found }
            if folder.path == rootPath { break }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        return last ?? mainFile
    }

    @objc func recompile(_ sender: Any?) {
        if compiler.isRunning {
            recompileQueued = true
            return
        }
        saveAll(interactive: true)
        for buffer in buffers.values { history.record(buffer.url, minimumInterval: 300) }
        guard let main = compileTarget() else {
            let alert = NSAlert()
            alert.messageText = L("Este proyecto no tiene un archivo .tex para compilar.", "This project has no .tex file to compile.")
            alert.informativeText = L("Creá uno o agregalo con el botón + de la barra lateral.", "Create one or add it with the + button in the sidebar.")
            alert.beginSheetModal(for: window!, completionHandler: nil)
            return
        }
        lastCompileTarget = main
        bar.setBusy(true)
        setStatus(L("Compilando…", "Compiling…"), .secondaryLabelColor)
        compiler.compile(main: main, engine: engine) { [weak self] result in
            self?.finish(result)
        }
    }

    @objc func recompileFromScratch(_ sender: Any?) {
        guard !compiler.isRunning else { return }
        compiler.clearBuildDirectory()
        recompile(sender)
    }

    @objc func stopCompile(_ sender: Any?) {
        recompileQueued = false
        DispatchQueue.global(qos: .userInitiated).async { [compiler] in compiler.cancel() }
    }

    private func finish(_ result: CompileResult) {
        guard !didClose else { return }
        bar.setBusy(false)

        if let message = result.setupError {
            setStatus(L("LaTeX no disponible", "LaTeX unavailable"), .systemRed)
            let alert = NSAlert()
            alert.messageText = message
            alert.beginSheetModal(for: window!, completionHandler: nil)
            return
        }

        lastResult = result
        if result.pdfData != nil { lastCompiledStem = lastCompileTarget?.deletingPathExtension().lastPathComponent }
        log.display(issues: result.issues, output: result.output)
        if !result.cancelled { showErrorMarks(result) }
        if let data = result.pdfData {
            pdfData = data
            pdfPane.display(data)
        }

        // Names the document whenever it isn't the project's main one, so a PDF never surprises.
        let document = lastCompileTarget.flatMap { target -> String? in
            target.standardizedFileURL.path == mainFile?.standardizedFileURL.path ? nil : relativePath(target) + " · "
        } ?? ""
        let seconds = document + String(format: "%.1f s", result.duration)
        if result.cancelled {
            setStatus(L("Compilación detenida", "Compilation stopped"), .secondaryLabelColor)
        } else if !result.issues.isEmpty {
            let count = result.issues.count
            setStatus(count == 1 ? "1 error · \(seconds)" : L("\(count) errores · \(seconds)", "\(count) errors · \(seconds)"), .systemRed)
        } else if result.pdfData == nil {
            setStatus(L("No se generó el PDF", "No PDF was generated"), .systemRed)
        } else if result.warningCount > 0 {
            let count = result.warningCount
            setStatus(L("Listo · \(count) \(count == 1 ? "advertencia" : "advertencias") · \(seconds)", "Ready · \(count) \(count == 1 ? "warning" : "warnings") · \(seconds)"), .systemOrange)
        } else {
            setStatus(L("Listo · \(seconds)", "Ready · \(seconds)"), .secondaryLabelColor)
        }

        if recompileQueued {
            recompileQueued = false
            recompile(nil)
        }
    }

    /// Project files written the way the document being compiled would refer to them.
    private func fileCompletions(_ kind: ProjectFileKind, query: String) -> [CompletionItem] {
        let base = (compileTarget()?.deletingLastPathComponent() ?? root).standardizedFileURL.pathComponents
        let tokens = BibParser.fold(query).split(separator: " ").map(String.init)
        let current = currentFile?.standardizedFileURL.path
        var items: [CompletionItem] = []
        for url in sidebar.projectFiles where kind.extensions.contains(url.pathExtension.lowercased()) {
            let file = url.standardizedFileURL
            guard file.path != current else { continue }
            let written = kind.keepsExtension ? file : file.deletingPathExtension()
            let parts = written.pathComponents
            var shared = 0
            while shared < base.count, shared < parts.count, base[shared] == parts[shared] { shared += 1 }
            let path = (Array(repeating: "..", count: base.count - shared) + parts[shared...]).joined(separator: "/")
            let folded = BibParser.fold(path)
            guard tokens.allSatisfy({ folded.contains($0) }) else { continue }
            items.append(CompletionItem(name: path, insert: path, title: path, detail: ""))
        }
        return Array(items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(40))
    }

    private func applyErrorMarks(to buffer: TextBuffer) {
        buffer.clearErrorMarks()
        for error in errorsByFile[buffer.url.standardizedFileURL.path] ?? [] {
            buffer.markError(line: error.line, message: error.message)
        }
    }

    private func showErrorMarks(_ result: CompileResult) {
        errorsByFile = [:]
        let rootPath = root.standardizedFileURL.path + "/"
        for issue in result.issues {
            guard let file = issue.file, let line = issue.line else { continue }
            let url = file.hasPrefix("/") ? URL(fileURLWithPath: file).standardizedFileURL
                                          : result.workingDirectory.appendingPathComponent(file).standardizedFileURL
            guard url.path.hasPrefix(rootPath), FileManager.default.fileExists(atPath: url.path) else { continue }
            errorsByFile[url.path, default: []].append((line, issue.message))
        }
        buffers.values.forEach(applyErrorMarks)
        leftEditor.refreshErrorMarks()
        rightEditor.refreshErrorMarks()
        refreshTabs()
    }

    /// Background saves stay quiet while the bar is showing something that matters more.
    func noteExport(_ text: String, _ color: NSColor) {
        guard !compiler.isRunning, lastResult?.issues.isEmpty != false else { return }
        setStatus(text, color)
    }

    func beginGitActivity(_ text: String) {
        bar.setBusy(true)
        setStatus(text, .secondaryLabelColor)
    }

    func endGitActivity(_ text: String) {
        if !compiler.isRunning { bar.setBusy(false) }
        setStatus(text, .secondaryLabelColor)
    }

    func setStatus(_ text: String, _ color: NSColor) {
        let theme = EditorTheme.current
        let isReady = color == .secondaryLabelColor && text.hasPrefix(L("Listo", "Ready"))
        let dot: NSColor? = isReady ? theme.ok : (color == .secondaryLabelColor ? nil : color)
        bar.setStatus(text, dot: dot, textColor: color == .systemRed ? .systemRed : theme.comment,
                      isSticky: color == .systemRed)
    }

    private func setLogVisible(_ visible: Bool) {
        logItem.animator().isCollapsed = !visible
    }

    @objc func toggleLog(_ sender: Any?) {
        setLogVisible(logItem.isCollapsed)
    }

    @objc func setEngine(_ sender: NSMenuItem) {
        guard Engine.allCases.indices.contains(sender.tag) else { return }
        engine = Engine.allCases[sender.tag]
        compiler.clearBuildDirectory()
        recompile(nil)
    }

    // MARK: - Download

    @objc func downloadPDF(_ sender: Any?) {
        guard let data = pdfData, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ((lastCompileTarget ?? mainFile)?.deletingPathExtension().lastPathComponent ?? root.lastPathComponent) + ".pdf"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = L("Descargar", "Download")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Project files

    @objc func saveAction(_ sender: Any?) {
        saveAll(interactive: true)
        if Self.compileOnSave { recompile(nil) }
    }

    private func askName(title: String, defaultValue: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    @objc func newFileAction(_ sender: Any?) {
        guard let name = askName(title: L("Nuevo archivo", "New File"), defaultValue: L("sin-titulo.tex", "untitled.tex"), confirm: L("Crear", "Create")) else { return }
        let url = (sidebar.targetDirectory ?? root).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showError(L("Ya existe un archivo llamado “\(name)”.", "A file named “\(name)” already exists."))
            return
        }
        do {
            try Data().write(to: url)
            sidebar.reload(selecting: url)
            open(url)
            editor.focus()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func newFolderAction(_ sender: Any?) {
        guard let name = askName(title: L("Nueva carpeta", "New Folder"), defaultValue: L("figuras", "figures"), confirm: L("Crear", "Create")) else { return }
        let url = (sidebar.targetDirectory ?? root).appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            sidebar.reload(selecting: shownURL)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func addFilesAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Agregar", "Add")
        panel.message = L("Los archivos se copian dentro del proyecto", "Files are copied into the project")
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, into: sidebar.targetDirectory ?? root)
    }

    func importFiles(_ urls: [URL], into directory: URL) {
        for source in urls {
            let destination = ProjectFiles.uniqueDestination(for: source.lastPathComponent, in: directory)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        sidebar.reload(selecting: shownURL)
    }

    func renameItem(_ url: URL) {
        saveAll(interactive: true)
        guard let name = askName(title: L("Renombrar", "Rename"), defaultValue: url.lastPathComponent, confirm: L("Renombrar", "Rename")),
              name != url.lastPathComponent else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        afterMove(from: url, to: destination)
    }

    func afterMove(from old: URL, to new: URL?) {
        if let new { history.moved(from: old, to: new) }
        let oldPath = old.standardizedFileURL.path
        let affects: (URL) -> Bool = { url in
            let path = url.standardizedFileURL.path
            return path == oldPath || path.hasPrefix(oldPath + "/")
        }
        let leftWasAffected = leftShown.map(affects) ?? false
        let rightWasAffected = rightShown.map(affects) ?? false
        let translate: (URL) -> URL? = { url in
            guard let new else { return nil }
            let suffix = String(url.standardizedFileURL.path.dropFirst(oldPath.count))
            return URL(fileURLWithPath: new.standardizedFileURL.path + suffix)
        }

        if let last = lastCompileTarget, affects(last) { lastCompileTarget = translate(last) }
        for path in Array(errorsByFile.keys) where affects(URL(fileURLWithPath: path)) {
            let errors = errorsByFile.removeValue(forKey: path)
            if let moved = translate(URL(fileURLWithPath: path)) { errorsByFile[moved.standardizedFileURL.path] = errors }
        }
        if let main = mainFile, affects(main) {
            if let moved = translate(main) {
                mainFile = moved
                storeSetting("main", relativePath(moved))
            } else {
                mainFile = nil
            }
        }
        let newLeft = leftWasAffected ? leftShown.flatMap(translate) : leftShown
        let newRight = rightWasAffected ? rightShown.flatMap(translate) : rightShown
        openTabs = openTabs.compactMap { affects($0) ? translate($0) : $0 }
        rightTabs = rightTabs.compactMap { affects($0) ? translate($0) : $0 }
        for (key, buffer) in buffers where affects(buffer.url) {
            buffers[key] = nil
            if let moved = translate(buffer.url) {
                buffer.url = moved
                buffer.modified = TextBuffer.modificationDate(of: moved)
                buffers[moved.standardizedFileURL.path] = buffer
            }
        }
        if mainFile == nil { mainFile = detectMainFile() }
        let previousColumn = activeColumn
        if leftWasAffected {
            leftShown = newLeft
            if let newLeft {
                open(newLeft, in: .left)
            } else {
                leftEditor.showNothing()
            }
        }
        if rightWasAffected {
            rightShown = newRight
            if let newRight {
                open(newRight, in: .right)
            } else {
                showPDFTab()
            }
        }
        activate(previousColumn)
        refreshTabs()
        sidebar.reload(selecting: shownURL)
    }

    func trashItem(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L("¿Mover “\(url.lastPathComponent)” a la papelera?", "Move “\(url.lastPathComponent)” to the Trash?")
        alert.addButton(withTitle: L("Mover a la papelera", "Move to Trash"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            afterMove(from: url, to: nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    // MARK: - View

    @objc func zoomInPDF(_ sender: Any?) { pdfPane.pdfView.zoomIn(sender) }
    @objc func zoomOutPDF(_ sender: Any?) { pdfPane.pdfView.zoomOut(sender) }
    @objc func zoomFitPDF(_ sender: Any?) { pdfPane.pdfView.autoScales = true }

    @objc func biggerFont(_ sender: Any?) {
        leftEditor.changeFontSize(by: 1, buffers: Array(buffers.values))
        rightEditor.changeFontSize(by: 1, buffers: Array(buffers.values))
    }

    @objc func smallerFont(_ sender: Any?) {
        leftEditor.changeFontSize(by: -1, buffers: Array(buffers.values))
        rightEditor.changeFontSize(by: -1, buffers: Array(buffers.values))
    }
}
