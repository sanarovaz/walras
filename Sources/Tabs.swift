import AppKit

// MARK: - Tab bar

extension NSPasteboard.PasteboardType {
    static let walrasTab = NSPasteboard.PasteboardType("io.github.sanarovaz.walras.tab")
}

private final class TabItemView: NSView, NSDraggingSource {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOthers: (() -> Void)?
    var onMove: (() -> Void)?
    var moveTitle = ""
    var canCloseOthers = false
    var dragURL: URL?

    /// AppKit doesn't promise to keep the source alive, and a drop rebuilds the tab bar.
    private static var viewBeingDragged: TabItemView?
    private var mouseDownEvent: NSEvent?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isSelected: Bool
    private let theme: EditorTheme

    init(title: String, tooltip: String, isSelected: Bool, hasError: Bool, theme: EditorTheme) {
        self.isSelected = isSelected
        self.theme = theme
        super.init(frame: .zero)
        toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
        label.textColor = hasError ? .systemRed : (isSelected ? theme.text : theme.comment)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Cerrar pestaña", "Close Tab"))?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = theme.comment
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = L("Cerrar pestaña (⌘W)", "Close Tab (⌘W)")
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        theme.accent.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1.5).fill()
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = onClose == nil }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    // Selecting rebuilds the tab bar, so it waits for the release: a drag needs this view alive.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let dragURL else { return }
        guard hypot(event.locationInWindow.x - start.locationInWindow.x,
                    event.locationInWindow.y - start.locationInWindow.y) > 5 else { return }
        mouseDownEvent = nil
        let contents = NSPasteboardItem()
        contents.setString(dragURL.standardizedFileURL.path, forType: .walrasTab)
        let item = NSDraggingItem(pasteboardWriter: contents)
        let image = NSImage(size: bounds.size)
        if let picture = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: picture)
            image.addRepresentation(picture)
        }
        item.setDraggingFrame(bounds, contents: image)
        Self.viewBeingDragged = self
        beginDraggingSession(with: [item], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onSelect?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { Self.viewBeingDragged = nil }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if onClose != nil { add(L("Cerrar", "Close"), #selector(closePressed)) }
        add(L("Cerrar todas menos esta", "Close All But This"), #selector(closeOthersPressed), enabled: canCloseOthers)
        if onMove != nil {
            menu.addItem(.separator())
            add(moveTitle, #selector(movePressed))
        }
        return menu
    }

    @objc private func closePressed() { onClose?() }
    @objc private func closeOthersPressed() { onCloseOthers?() }
    @objc private func movePressed() { onMove?() }
}

final class EditorTabBar: NSView {
    /// Stands for the compiled PDF in the right column's tab list. It can't be closed or dragged.
    static let pdfURL = URL(fileURLWithPath: "/walras-pdf-tab")

    var onSelect: ((URL) -> Void)?
    var onClose: ((URL) -> Void)?
    var onCloseOthers: ((URL) -> Void)?
    var onMove: ((URL) -> Void)?
    var moveTitle = ""

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private var backgroundColor: NSColor = EditorTheme.current.tabBar
    private var scrollLeading: NSLayoutConstraint!
    private static let spaceForLogo: CGFloat = 52

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .height
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scrollLeading = scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.spaceForLogo)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollLeading,
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// With the sidebar closed, the window's fixed image sits over this bar's left end.
    func setLeavesRoomForLogo(_ leavesRoom: Bool) {
        scrollLeading.constant = leavesRoom ? Self.spaceForLogo : 8
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
    }

    /// `titles` holds the text for each tab; it adds the folder when two files share a name.
    func display(tabs: [(url: URL, title: String, tooltip: String)], selected: URL?, errorPaths: Set<String> = []) {
        let theme = EditorTheme.current
        backgroundColor = theme.tabBar
        needsDisplay = true
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let selectedPath = selected?.standardizedFileURL.path
        for tab in tabs {
            let isSelected = tab.url.standardizedFileURL.path == selectedPath
            let view = TabItemView(title: tab.title, tooltip: tab.tooltip, isSelected: isSelected,
                                   hasError: errorPaths.contains(tab.url.standardizedFileURL.path), theme: theme)
            let isPDF = tab.url == Self.pdfURL
            view.onSelect = { [weak self] in self?.onSelect?(tab.url) }
            view.onCloseOthers = { [weak self] in self?.onCloseOthers?(tab.url) }
            view.canCloseOthers = tabs.contains { $0.url != tab.url && $0.url != Self.pdfURL }
            if !isPDF {
                view.onClose = { [weak self] in self?.onClose?(tab.url) }
                view.onMove = { [weak self] in self?.onMove?(tab.url) }
                view.moveTitle = moveTitle
                view.dragURL = tab.url
            }
            stack.addArrangedSubview(view)
            if isSelected {
                DispatchQueue.main.async { view.scrollToVisible(view.bounds) }
            }
        }
    }
}

// MARK: - Dropping tabs

/// A column that takes tabs dragged from the other one, tinted while one hovers over it.
final class TabDropView: NSView {
    var canAccept: ((URL) -> Bool)?
    var onDrop: ((URL) -> Void)? {
        didSet { registerForDraggedTypes([.walrasTab]) }
    }

    private lazy var tint: NSView = {
        let tint = NSView()
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        return tint
    }()

    private func tabURL(_ sender: NSDraggingInfo) -> URL? {
        guard let path = sender.draggingPasteboard.string(forType: .walrasTab) else { return nil }
        let url = URL(fileURLWithPath: path)
        return canAccept?(url) == true ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard tabURL(sender) != nil else { return [] }
        tint.frame = bounds
        tint.layer?.backgroundColor = EditorTheme.current.accent.withAlphaComponent(0.14).cgColor
        addSubview(tint, positioned: .above, relativeTo: nil)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { tint.removeFromSuperview() }
    override func draggingEnded(_ sender: NSDraggingInfo) { tint.removeFromSuperview() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        tint.removeFromSuperview()
        guard let url = tabURL(sender) else { return false }
        // After the drag ends, since this rebuilds the tab the drag started from.
        DispatchQueue.main.async { [weak self] in self?.onDrop?(url) }
        return true
    }
}

/// The right column: the PDF alone, or the PDF and code under a row of tabs.
final class RightPaneViewController: NSViewController {
    let tabBar = EditorTabBar()
    private let pdf: NSViewController
    private let editor: NSViewController
    private var tabBarHeight: NSLayoutConstraint!

    init(pdf: NSViewController, editor: NSViewController) {
        self.pdf = pdf
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = TabDropView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.setLeavesRoomForLogo(false)
        tabBar.isHidden = true
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        root.addSubview(tabBar)
        var constraints = [
            tabBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight!,
        ]
        for child in [pdf, editor] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child.view)
            constraints += [
                child.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                child.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        editor.view.isHidden = true
        view = root
    }

    func setTabsVisible(_ visible: Bool) {
        _ = view
        tabBar.isHidden = !visible
        tabBarHeight.constant = visible ? 40 : 0
    }

    func show(pdf showsPDF: Bool) {
        _ = view
        pdf.view.isHidden = !showsPDF
        editor.view.isHidden = showsPDF
    }
}

// MARK: - Quick open

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// ⌘P: type part of a file's name and press return.
final class QuickOpenController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((URL) -> Void)?

    private struct Entry {
        let url: URL
        let name: String
        let folder: String
    }

    private let panel: KeyablePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private var everything: [Entry] = []
    private var shown: [Entry] = []
    private weak var parent: NSWindow?
    private static let width: CGFloat = 520
    private static let height: CGFloat = 340

    override init() {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        field.placeholderString = L("Abrir archivo del proyecto", "Open project file")
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(field)
        background.addSubview(separator)
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
        panel.contentView = background

        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    /// `files` holds project-relative paths; those at the start appear first with nothing typed.
    func show(files: [(url: URL, path: String)], in window: NSWindow) {
        everything = files.map { file in
            let path = file.path as NSString
            return Entry(url: file.url, name: path.lastPathComponent, folder: path.deletingLastPathComponent)
        }
        field.stringValue = ""
        filter()
        let frame = window.frame
        let origin = NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - Self.height - 90)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: Self.height)), display: true)
        parent = window
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    @objc private func lostFocus() {
        dismiss()
    }

    private func filter() {
        let query = BibParser.fold(field.stringValue.trimmingCharacters(in: .whitespaces))
        if query.isEmpty {
            shown = everything
        } else {
            let scored = everything.compactMap { entry -> (Entry, Int)? in
                Self.score(query, entry).map { (entry, $0) }
            }
            shown = scored.sorted { $0.1 > $1.1 }.map(\.0)
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    /// File-name hits beat folder hits, and contiguous matches beat scattered letters.
    private static func score(_ query: String, _ entry: Entry) -> Int? {
        let name = BibParser.fold(entry.name)
        let full = BibParser.fold(entry.folder.isEmpty ? entry.name : entry.folder + "/" + entry.name)
        if name.hasPrefix(query) { return 3000 - name.count }
        if name.contains(query) { return 2000 - name.count }
        if full.contains(query) { return 1000 - full.count }
        var remaining = Substring(query)
        for character in full {
            if character == remaining.first { remaining = remaining.dropFirst() }
            if remaining.isEmpty { return 100 - min(99, full.count) }
        }
        return nil
    }

    private func openSelected(_ row: Int) {
        guard shown.indices.contains(row) else { return }
        let url = shown[row].url
        dismiss()
        onOpen?(url)
    }

    @objc private func clicked() {
        openSelected(table.clickedRow)
    }

    func controlTextDidChange(_ obj: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            openSelected(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let next = min(shown.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("quickOpen")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let entry = shown[row]
        let text = NSMutableAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        if !entry.folder.isEmpty {
            text.append(NSAttributedString(string: "   " + entry.folder, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        cell.textField?.attributedStringValue = text
        return cell
    }
}
