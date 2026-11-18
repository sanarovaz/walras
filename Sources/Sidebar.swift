import AppKit
import UniformTypeIdentifiers

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode] = []

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var key: String { url.standardizedFileURL.path }
}

enum ProjectFiles {
    /// Build by-products that may exist in older projects and only add clutter.
    private static let hiddenExtensions: Set<String> = [
        "aux", "log", "out", "toc", "fls", "fdb_latexmk", "bbl", "blg", "bcf", "lof", "lot",
        "nav", "snm", "vrb", "xdv", "dvi", "idx", "ilg", "ind", "synctex",
    ]

    static func isHidden(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasSuffix(".synctex.gz") || name.hasSuffix(".run.xml") { return true }
        return hiddenExtensions.contains(url.pathExtension.lowercased())
    }

    static func scan(_ directory: URL) -> [FileNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var nodes: [FileNode] = []
        for url in urls where !isHidden(url) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true && values?.isPackage != true
            let node = FileNode(url: url, isDirectory: isDirectory)
            if isDirectory { node.children = scan(url) }
            nodes.append(node)
        }
        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return !lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    private static let textExtensions: Set<String> = [
        "tex", "bib", "sty", "cls", "bst", "bbx", "cbx", "lbx", "def", "cfg", "clo", "ltx", "dtx", "ins",
        "tikz", "pgf", "txt", "md", "csv", "tsv", "do", "r", "rmd", "py", "m", "jl", "json", "yaml", "yml",
    ]

    static func isText(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        if ext.isEmpty { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .text) == true
    }

    static func textFiles(in nodes: [FileNode]) -> [URL] {
        var files: [URL] = []
        for node in nodes {
            if node.isDirectory {
                files += textFiles(in: node.children)
            } else if isText(node.url) {
                files.append(node.url)
            }
        }
        return files
    }

    static func allFiles(in nodes: [FileNode]) -> [URL] {
        var files: [URL] = []
        for node in nodes {
            if node.isDirectory {
                files += allFiles(in: node.children)
            } else {
                files.append(node.url)
            }
        }
        return files
    }

    static func symbolName(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        let ext = node.url.pathExtension.lowercased()
        switch ext {
        case "tex", "sty", "cls": return "doc.text"
        case "bib", "bst": return "books.vertical"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "eps", "svg": return "photo"
        case "csv", "tsv": return "tablecells"
        default: return "doc"
        }
    }

    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var count = 2
        while fm.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) \(count)" : "\(stem) \(count).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            count += 1
        }
        return candidate
    }
}

enum SidebarTab: Int {
    case files, index, search
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var project: ProjectWindowController?

    let indexPane = IndexPaneView()
    let searchPane = SearchPaneView()

    private let outline = NSOutlineView()
    private let filesPane = NSView()
    private var tabs: NSStackView!
    private var tabButtons: [SideTabButton] = []
    private var nodes: [FileNode] = []
    private var suppressSelection = false

    override func loadView() {
        let container = ThemedBackgroundView { $0.sidebar }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .custom
        outline.rowHeight = 25
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = true
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.registerForDraggedTypes([.fileURL])

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outline.menu = contextMenu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L("Agregar", "Add"))!,
                                 target: self, action: #selector(showAddMenu(_:)))
        addButton.isBordered = false
        addButton.contentTintColor = EditorTheme.current.icon
        addButton.toolTip = L("Agregar archivos o carpetas", "Add files or folders")
        addButton.translatesAutoresizingMaskIntoConstraints = false

        filesPane.addSubview(scroll)
        filesPane.addSubview(addButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: filesPane.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: filesPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: filesPane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),
            addButton.leadingAnchor.constraint(equalTo: filesPane.leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: filesPane.bottomAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        let symbols = ["folder", "list.bullet.indent", "magnifyingglass"]
        let tips = [L("Archivos (⌥⌘1)", "Files (⌥⌘1)"), L("Índice (⌥⌘2)", "Outline (⌥⌘2)"), L("Buscar en el proyecto (⇧⌘F)", "Find in Project (⇧⌘F)")]
        tabButtons = zip(symbols, tips).enumerated().map { index, entry in
            let image = NSImage(systemSymbolName: entry.0, accessibilityDescription: entry.1)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage()
            let button = SideTabButton(image: image, target: self, action: #selector(tabChanged(_:)))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.tag = index
            button.toolTip = entry.1
            button.contentTintColor = EditorTheme.current.icon
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        }
        tabButtons[0].isCurrent = true
        tabs = NSStackView(views: tabButtons)
        tabs.spacing = 4
        tabs.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabs)

        let panes: [NSView] = [filesPane, indexPane, searchPane]
        for pane in panes {
            pane.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
                pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            // To the right of the window's fixed image.
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 50),
        ])
        indexPane.isHidden = true
        searchPane.isHidden = true

        indexPane.onSelect = { [weak self] url, line in
            self?.project?.openLocation(url, line: line, column: 0, length: 0)
        }
        searchPane.onSelect = { [weak self] match in
            self?.project?.openLocation(match.url, line: match.line, column: match.column, length: match.length)
        }
        searchPane.snapshotProvider = { [weak self] in self?.project?.openBufferTexts() ?? [:] }
        searchPane.onReplaceAll = { [weak self] query, replacement, files in
            self?.project?.replaceInProject(query, with: replacement, files: files)
        }
        searchPane.filesProvider = { [weak self] in
            guard let self, let project = self.project else { return [] }
            return ProjectFiles.textFiles(in: self.nodes).map { (url: $0, name: project.relativePath($0)) }
        }
        view = container
    }

    func show(_ tab: SidebarTab) {
        _ = view
        for button in tabButtons { button.isCurrent = button.tag == tab.rawValue }
        filesPane.isHidden = tab != .files
        indexPane.isHidden = tab != .index
        searchPane.isHidden = tab != .search
        if tab == .index { project?.refreshIndexNow() }
        if tab == .search { searchPane.focus() }
    }

    var isShowingIndex: Bool { !indexPane.isHidden }

    var projectFiles: [URL] { ProjectFiles.allFiles(in: nodes) }

    @objc private func tabChanged(_ sender: NSButton) {
        if let tab = SidebarTab(rawValue: sender.tag) { show(tab) }
    }

    func applyTheme() {
        _ = view
        view.needsDisplay = true
        for button in tabButtons { button.contentTintColor = EditorTheme.current.icon }
        outline.reloadData()
        indexPane.refreshForTheme()
        searchPane.refreshForTheme()
        if let project { reload(selecting: project.currentFile) }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    private func allPaths(_ list: [FileNode]) -> [String] {
        list.flatMap { [$0.key] + allPaths($0.children) }
    }

    /// For background changes: leaves the list alone unless a file came or went,
    /// so that saving doesn't disturb its scroll position.
    func reloadIfChanged(selecting selected: URL?) {
        guard let project else { return }
        if allPaths(ProjectFiles.scan(project.root)) != allPaths(nodes) { reload(selecting: selected) }
    }

    func reload(selecting selected: URL?) {
        guard let project else { return }
        let expanded = expandedKeys()
        nodes = ProjectFiles.scan(project.root)
        suppressSelection = true
        outline.reloadData()
        restoreExpansion(nodes, expanded)
        if let selected { select(selected) }
        suppressSelection = false
    }

    func select(_ url: URL) {
        let key = url.standardizedFileURL.path
        // From the outside in: a folder can't open while its parent is closed.
        for folder in path(to: key, in: nodes).dropLast() { outline.expandItem(folder) }
        let wasSuppressed = suppressSelection
        suppressSelection = true
        for row in 0..<outline.numberOfRows {
            if (outline.item(atRow: row) as? FileNode)?.key == key {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                break
            }
        }
        suppressSelection = wasSuppressed
    }

    /// Folder that new or imported files should go into.
    var targetDirectory: URL? {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return nil }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func expandedKeys() -> Set<String> {
        var keys = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) {
                keys.insert(node.key)
            }
        }
        return keys
    }

    private func restoreExpansion(_ list: [FileNode], _ keys: Set<String>) {
        for node in list where node.isDirectory && keys.contains(node.key) {
            outline.expandItem(node)
            restoreExpansion(node.children, keys)
        }
    }

    private func path(to key: String, in list: [FileNode]) -> [FileNode] {
        for node in list {
            if node.key == key { return [node] }
            if node.isDirectory {
                let rest = path(to: key, in: node.children)
                if !rest.isEmpty { return [node] + rest }
            }
        }
        return []
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        guard let project else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: L("Nuevo archivo…", "New File…"), action: #selector(ProjectWindowController.newFileAction(_:)), keyEquivalent: "").target = project
        menu.addItem(withTitle: L("Nueva carpeta…", "New Folder…"), action: #selector(ProjectWindowController.newFolderAction(_:)), keyEquivalent: "").target = project
        menu.addItem(withTitle: L("Agregar archivos…", "Add Files…"), action: #selector(ProjectWindowController.addFilesAction(_:)), keyEquivalent: "").target = project
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileNode)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 0),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let isMain = project?.mainFile?.standardizedFileURL.path == node.key
        cell.textField?.textColor = EditorTheme.current.text
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.textField?.font = .systemFont(ofSize: 12.5, weight: isMain ? .semibold : .regular)
        cell.toolTip = isMain ? L("Archivo principal", "Main file") : nil
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory else { return }
        project?.open(node.url)
    }

    // MARK: - Drop from Finder

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let node = item as? FileNode, !node.isDirectory {
            let parent = outlineView.parent(forItem: node)
            outlineView.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let project else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        project.importFiles(urls, into: (item as? FileNode)?.url ?? project.root)
        return true
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let project else { return }
        let node = outline.item(atRow: outline.clickedRow) as? FileNode

        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
        }
        if let node {
            if !node.isDirectory, node.url.pathExtension.lowercased() == "tex" {
                add(L("Usar como archivo principal", "Use as Main File"), #selector(makeMain(_:)))
                menu.addItem(.separator())
            }
            add(L("Renombrar…", "Rename…"), #selector(rename(_:)))
            add(L("Mostrar en Finder", "Show in Finder"), #selector(reveal(_:)))
            menu.addItem(.separator())
            add(L("Mover a la papelera", "Move to Trash"), #selector(trash(_:)))
        } else {
            menu.addItem(withTitle: L("Nuevo archivo…", "New File…"), action: #selector(ProjectWindowController.newFileAction(_:)), keyEquivalent: "").target = project
            menu.addItem(withTitle: L("Agregar archivos…", "Add Files…"), action: #selector(ProjectWindowController.addFilesAction(_:)), keyEquivalent: "").target = project
        }
    }

    @objc private func makeMain(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { project?.setMainFile(node.url) }
    }

    @objc private func rename(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { project?.renameItem(node.url) }
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }

    @objc private func trash(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FileNode { project?.trashItem(node.url) }
    }
}
