import AppKit

// MARK: - Shared helpers

private func configureSourceList(_ outline: NSOutlineView, owner: NSOutlineViewDataSource & NSOutlineViewDelegate) {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.headerView = nil
    outline.style = .plain
    outline.backgroundColor = .clear
    outline.rowSizeStyle = .custom
    outline.rowHeight = 25
    outline.indentationPerLevel = 12
    outline.intercellSpacing = NSSize(width: 0, height: 1)
    outline.autoresizesOutlineColumn = true
    outline.dataSource = owner
    outline.delegate = owner
}

private func makeScroll(for outline: NSOutlineView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = outline
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return scroll
}

private func makeTextCell(_ outline: NSOutlineView, identifier: String, owner: Any) -> NSTableCellView {
    let id = NSUserInterfaceItemIdentifier(identifier)
    if let reused = outline.makeView(withIdentifier: id, owner: owner) as? NSTableCellView {
        reused.textField?.textColor = EditorTheme.current.text
        return reused
    }
    let cell = NSTableCellView()
    cell.identifier = id
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.textColor = EditorTheme.current.text
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.textField = label
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
}

private func makeEmptyLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.alignment = .center
    label.textColor = EditorTheme.current.comment
    label.font = .systemFont(ofSize: 12)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

// MARK: - Document outline

final class OutlineItem: NSObject {
    let title: String
    let level: Int
    let url: URL
    let line: Int
    var children: [OutlineItem] = []

    init(title: String, level: Int, url: URL, line: Int) {
        self.title = title
        self.level = level
        self.url = url
        self.line = line
    }
}

enum DocumentOutline {
    private static let levels: [String: Int] = [
        "part": 0, "addpart": 0, "chapter": 1, "addchap": 1, "section": 2, "addsec": 2,
        "subsection": 3, "subsubsection": 4, "paragraph": 5, "frametitle": 6,
    ]
    private static let command = try! NSRegularExpression(pattern:
        "\\\\(part|addpart|chapter|addchap|section|addsec|subsection|subsubsection|paragraph|frametitle|input|include|subfile)\\*?(?:\\[[^\\]]*\\])?\\s*\\{")
    private static let frame = try! NSRegularExpression(pattern:
        "\\\\begin\\{frame\\}(?:<[^>]*>)?(?:\\[[^\\]]*\\])?\\{")

    /// Follows \input and \include from the main file. `textFor` returns the
    /// editor's current text when the file is open, so the outline tracks edits.
    static func build(main: URL, textFor: (URL) -> String?) -> [OutlineItem] {
        var flat: [OutlineItem] = []
        var visited = Set<String>()
        walk(main, base: main.deletingLastPathComponent(), textFor: textFor, visited: &visited, into: &flat)

        var roots: [OutlineItem] = []
        var stack: [OutlineItem] = []
        for item in flat {
            while let top = stack.last, top.level >= item.level { stack.removeLast() }
            if let parent = stack.last {
                parent.children.append(item)
            } else {
                roots.append(item)
            }
            stack.append(item)
        }
        return roots
    }

    private static func walk(_ url: URL, base: URL, textFor: (URL) -> String?,
                             visited: inout Set<String>, into flat: inout [OutlineItem]) {
        guard visited.insert(url.standardizedFileURL.path).inserted, let text = textFor(url) else { return }
        var lineNumber = 0
        var lines: [String] = []
        text.enumerateLines { line, _ in lines.append(line) }
        for raw in lines {
            lineNumber += 1
            guard raw.contains("\\") else { continue }
            let line = stripComment(raw) as NSString
            let full = NSRange(location: 0, length: line.length)
            var found: [(location: Int, name: String, contentStart: Int)] = []
            for match in command.matches(in: line as String, options: [], range: full) {
                found.append((match.range.location, line.substring(with: match.range(at: 1)), NSMaxRange(match.range)))
            }
            for match in frame.matches(in: line as String, options: [], range: full) {
                found.append((match.range.location, "frametitle", NSMaxRange(match.range)))
            }
            found.sort { $0.location < $1.location }
            for hit in found {
                let argument = bracedArgument(in: line, from: hit.contentStart)
                if let level = levels[hit.name] {
                    let title = clean(argument)
                    if !title.isEmpty {
                        flat.append(OutlineItem(title: title, level: level, url: url, line: lineNumber))
                    }
                } else {
                    var path = argument.trimmingCharacters(in: .whitespaces)
                    if path.isEmpty { continue }
                    if (path as NSString).pathExtension.isEmpty { path += ".tex" }
                    let included = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                    walk(included, base: base, textFor: textFor, visited: &visited, into: &flat)
                }
            }
        }
    }

    private static func stripComment(_ line: String) -> String {
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "%" { return String(characters[..<index]) }
            index += 1
        }
        return line
    }

    private static func bracedArgument(in line: NSString, from start: Int) -> String {
        var depth = 1
        var index = start
        while index < line.length {
            let unit = line.character(at: index)
            if unit == 92 { // backslash
                index += 2
                continue
            }
            if unit == 123 { depth += 1 }
            if unit == 125 {
                depth -= 1
                if depth == 0 { return line.substring(with: NSRange(location: start, length: index - start)) }
            }
            index += 1
        }
        return start <= line.length ? line.substring(from: start) : ""
    }

    private static func clean(_ title: String) -> String {
        title.replacingOccurrences(of: "\\\\", with: " ")
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "\\textbf{", with: "")
            .replacingOccurrences(of: "\\textit{", with: "")
            .replacingOccurrences(of: "\\emph{", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

final class IndexPaneView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((URL, Int) -> Void)?

    private let outline = NSOutlineView()
    private var items: [OutlineItem] = []
    private var isReloading = false
    private let emptyLabel = makeEmptyLabel(L("No encontré secciones en el archivo principal.", "No sections found in the main file."))

    init() {
        super.init(frame: .zero)
        configureSourceList(outline, owner: self)
        let scroll = makeScroll(for: outline)
        addSubview(scroll)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func display(_ newItems: [OutlineItem]) {
        isReloading = true
        items = newItems
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        emptyLabel.isHidden = !newItems.isEmpty
        isReloading = false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func refreshForTheme() {
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? OutlineItem)?.children.count ?? items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? OutlineItem)?.children[index] ?? items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? OutlineItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? OutlineItem else { return nil }
        let cell = makeTextCell(outlineView, identifier: "outline", owner: self)
        cell.textField?.stringValue = item.title
        cell.textField?.font = .systemFont(ofSize: 12, weight: item.level <= 2 ? .medium : .regular)
        cell.toolTip = item.title
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let item = outline.item(atRow: outline.selectedRow) as? OutlineItem else { return }
        onSelect?(item.url, item.line)
    }
}

// MARK: - Project search

final class SearchFile: NSObject {
    let url: URL
    let name: String
    var matches: [SearchMatch] = []

    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

final class SearchMatch: NSObject {
    let url: URL
    let line: Int
    let column: Int
    let length: Int
    let preview: NSAttributedString

    init(url: URL, line: Int, column: Int, length: Int, preview: NSAttributedString) {
        self.url = url
        self.line = line
        self.column = column
        self.length = length
        self.preview = preview
    }
}

final class SearchPaneView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((SearchMatch) -> Void)?
    /// Current text of open files, so that unsaved edits are searched too.
    var snapshotProvider: (() -> [String: String])?
    var filesProvider: (() -> [(url: URL, name: String)])?
    var onReplaceAll: ((_ query: String, _ replacement: String, _ files: [URL]) -> Void)?

    private static let maximumResults = 2000

    private let field = NSSearchField()
    private let replaceField = NSTextField()
    private var replaceButton: NSButton!
    private let outline = NSOutlineView()
    private let statusLabel = makeEmptyLabel(L("Buscá en todos los archivos de texto del proyecto.", "Search all of the project's text files."))
    private var results: [SearchFile] = []
    private var generation = 0
    private var isReloading = false

    init() {
        super.init(frame: .zero)
        field.placeholderString = L("Buscar en el proyecto", "Search in Project")
        field.controlSize = .small
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(runSearch)
        field.translatesAutoresizingMaskIntoConstraints = false

        replaceField.placeholderString = L("Reemplazar por", "Replace with")
        replaceField.controlSize = .small
        replaceField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceButton = NSButton(title: L("Todo", "All"), target: self, action: #selector(replaceAllPressed))
        replaceButton.controlSize = .small
        replaceButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replaceButton.toolTip = L("Reemplazar en todo el proyecto", "Replace in the whole project")
        replaceButton.isEnabled = false
        replaceButton.translatesAutoresizingMaskIntoConstraints = false
        replaceButton.setContentHuggingPriority(.required, for: .horizontal)

        configureSourceList(outline, owner: self)
        let scroll = makeScroll(for: outline)
        addSubview(field)
        addSubview(replaceField)
        addSubview(replaceButton)
        addSubview(scroll)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            replaceField.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            replaceField.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            replaceField.trailingAnchor.constraint(equalTo: replaceButton.leadingAnchor, constant: -6),
            replaceButton.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            replaceButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            statusLabel.topAnchor.constraint(equalTo: replaceField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focus() {
        window?.makeFirstResponder(field)
    }

    func refreshResults() {
        runSearch()
    }

    @objc private func replaceAllPressed() {
        let query = field.stringValue
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
        onReplaceAll?(query, replaceField.stringValue, (filesProvider?() ?? []).map { $0.url })
    }

    @objc private func runSearch() {
        let query = field.stringValue
        generation += 1
        let current = generation
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            show([], status: L("Escribí al menos dos letras.", "Type at least two letters."))
            return
        }
        let snapshot = snapshotProvider?() ?? [:]
        let files = filesProvider?() ?? []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (found, total) = Self.search(query, files: files, snapshot: snapshot)
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                var status: String
                if total == 0 {
                    status = L("Sin resultados.", "No results.")
                } else {
                    status = L("\(total) \(total == 1 ? "resultado" : "resultados") en \(found.count) \(found.count == 1 ? "archivo" : "archivos").", "\(total) \(total == 1 ? "result" : "results") in \(found.count) \(found.count == 1 ? "file" : "files").")
                    if total >= Self.maximumResults { status += L(" Muestro solo los primeros.", " Showing only the first ones.") }
                }
                self.show(found, status: status)
            }
        }
    }

    private func show(_ files: [SearchFile], status: String) {
        isReloading = true
        results = files
        replaceButton.isEnabled = !files.isEmpty
        statusLabel.stringValue = status
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        isReloading = false
    }

    private static func search(_ query: String, files: [(url: URL, name: String)],
                               snapshot: [String: String]) -> ([SearchFile], Int) {
        var found: [SearchFile] = []
        var total = 0
        for file in files {
            if total >= maximumResults { break }
            let text: String
            if let open = snapshot[file.url.standardizedFileURL.path] {
                text = open
            } else if let data = try? Data(contentsOf: file.url), data.count < 5_000_000, !data.contains(0) {
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            } else {
                continue
            }
            let result = SearchFile(url: file.url, name: file.name)
            var lineNumber = 0
            text.enumerateLines { line, stop in
                lineNumber += 1
                let nsLine = line as NSString
                var searchStart = 0
                while searchStart < nsLine.length {
                    let range = nsLine.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                             range: NSRange(location: searchStart, length: nsLine.length - searchStart))
                    if range.location == NSNotFound { break }
                    result.matches.append(SearchMatch(url: file.url, line: lineNumber, column: range.location,
                                                      length: range.length,
                                                      preview: preview(of: nsLine, match: range)))
                    total += 1
                    searchStart = NSMaxRange(range)
                    if total >= maximumResults {
                        stop = true
                        break
                    }
                }
            }
            if !result.matches.isEmpty { found.append(result) }
        }
        return (found, total)
    }

    private static func preview(of line: NSString, match: NSRange) -> NSAttributedString {
        var start = max(0, match.location - 24)
        while start < match.location, CharacterSet.whitespaces.contains(UnicodeScalar(line.character(at: start)) ?? " ") {
            start += 1
        }
        let end = min(line.length, NSMaxRange(match) + 120)
        let visible = line.substring(with: NSRange(location: start, length: end - start))
        let text = NSMutableAttributedString(string: visible, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: EditorTheme.current.comment,
        ])
        let highlighted = NSRange(location: match.location - start, length: match.length)
        text.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: EditorTheme.current.text,
        ], range: highlighted)
        return text
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func refreshForTheme() {
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SearchFile)?.matches.count ?? (item == nil ? results.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let file = item as? SearchFile { return file.matches[index] }
        return results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchFile
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let file = item as? SearchFile {
            let cell = makeTextCell(outlineView, identifier: "searchFile", owner: self)
            cell.textField?.stringValue = "\(file.name) (\(file.matches.count))"
            cell.textField?.font = .systemFont(ofSize: 12, weight: .semibold)
            return cell
        }
        if let match = item as? SearchMatch {
            let cell = makeTextCell(outlineView, identifier: "searchMatch", owner: self)
            cell.textField?.attributedStringValue = match.preview
            cell.toolTip = L("Línea \(match.line)", "Line \(match.line)")
            return cell
        }
        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let match = outline.item(atRow: outline.selectedRow) as? SearchMatch else { return }
        onSelect?(match)
    }
}
