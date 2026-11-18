import AppKit
import UniformTypeIdentifiers

struct PaperResult {
    let doi: String
    let type: String
    let title: String
    let authors: [(given: String, family: String)]
    let year: String
    let venue: String
    let volume: String
    let issue: String
    let pages: String
    let publisher: String

    var authorSummary: String {
        let surnames = authors.map { $0.family }
        switch surnames.count {
        case 0: return ""
        case 1: return surnames[0]
        case 2: return L("\(surnames[0]) y \(surnames[1])", "\(surnames[0]) and \(surnames[1])")
        default: return "\(surnames[0]) et al."
        }
    }

    var detail: String {
        var parts: [String] = []
        let who = year.isEmpty ? authorSummary : "\(authorSummary) (\(year))"
        if !who.isEmpty { parts.append(who) }
        if !venue.isEmpty { parts.append(venue) }
        return parts.joined(separator: " · ")
    }

    private func latexEscaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "&%#_$".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A citation key in the usual style: surname, year, first significant word of the title.
    func makeKey(avoiding existing: Set<String>) -> String {
        func ascii(_ text: String) -> String {
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            return String(folded.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
        let surname = ascii((authors.first?.family ?? "").split(separator: " ").last.map(String.init) ?? "")
        let skip: Set<String> = ["the", "a", "an", "on", "of", "in", "and", "for", "el", "la", "los", "las", "un", "una", "de"]
        let word = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { ascii(String($0)) }
            .first { !$0.isEmpty && !skip.contains($0) } ?? ""
        let base = (surname.isEmpty ? "ref" : surname) + year + word
        if !existing.contains(base) { return base }
        for suffix in "abcdefghijklmnopqrstuvwxyz" where !existing.contains(base + String(suffix)) {
            return base + String(suffix)
        }
        return base + UUID().uuidString.prefix(4).lowercased()
    }

    func bibtex(key: String) -> String {
        let entryType: String
        var venueField = "journal"
        switch type {
        case "journal-article":
            entryType = "article"
        case "book", "monograph", "edited-book", "reference-book":
            entryType = "book"
            venueField = ""
        case "book-chapter", "book-section", "book-part", "reference-entry":
            entryType = "incollection"
            venueField = "booktitle"
        case "proceedings-article":
            entryType = "inproceedings"
            venueField = "booktitle"
        case "report", "report-component":
            entryType = "techreport"
            venueField = "institution"
        default:
            entryType = "misc"
            venueField = "howpublished"
        }

        var fields: [(String, String)] = []
        if !authors.isEmpty {
            let names = authors.map { author -> String in
                let family = latexEscaped(author.family)
                return author.given.isEmpty ? "{\(family)}" : "\(family), \(latexEscaped(author.given))"
            }
            fields.append(("author", names.joined(separator: " and ")))
        }
        fields.append(("title", latexEscaped(title)))
        if !venue.isEmpty, !venueField.isEmpty { fields.append((venueField, latexEscaped(venue))) }
        if !year.isEmpty { fields.append(("year", year)) }
        if !volume.isEmpty { fields.append(("volume", latexEscaped(volume))) }
        if !issue.isEmpty { fields.append(("number", latexEscaped(issue))) }
        if !pages.isEmpty { fields.append(("pages", latexEscaped(pages.replacingOccurrences(of: "-", with: "--")))) }
        if !publisher.isEmpty, entryType == "book" || entryType == "incollection" {
            fields.append(("publisher", latexEscaped(publisher)))
        }
        if !doi.isEmpty { fields.append(("doi", doi)) }

        let width = fields.map { $0.0.count }.max() ?? 0
        let body = fields.map { name, value in
            "  \(name.padding(toLength: width, withPad: " ", startingAt: 0)) = {\(value)}"
        }.joined(separator: ",\n")
        return "@\(entryType){\(key),\n\(body)\n}\n"
    }
}

enum CrossrefClient {
    enum Failure: Error {
        case offline, other(String)

        var message: String {
            switch self {
            case .offline: return L("No pude conectarme con Crossref. Revisá la conexión.", "Couldn't reach Crossref. Check your connection.")
            case .other(let detail): return L("Crossref devolvió un error: \(detail)", "Crossref returned an error: \(detail)")
            }
        }
    }

    private static let ignoredTypes: Set<String> = [
        "journal-issue", "journal-volume", "journal", "component", "peer-review", "dataset", "grant", "database",
        "standard", "book-series", "book-set", "proceedings", "other",
    ]

    /// Only the typed text leaves the Mac. No identifying contact details are sent.
    @discardableResult
    static func search(_ query: String, completion: @escaping (Result<[PaperResult], Failure>) -> Void) -> URLSessionDataTask? {
        var components = URLComponents(string: "https://api.crossref.org/works")
        components?.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: query),
            URLQueryItem(name: "rows", value: "25"),
            URLQueryItem(name: "select", value: "DOI,type,title,author,issued,container-title,volume,issue,page,publisher"),
        ]
        guard let url = components?.url else {
            completion(.failure(.other(L("búsqueda inválida", "invalid search"))))
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Walras/1.0", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
            let result: Result<[PaperResult], Failure>
            if error != nil {
                result = .failure(.offline)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(.other(L("código \(http.statusCode)", "code \(http.statusCode)")))
            } else {
                result = .success(parse(data ?? Data()))
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    private static func parse(_ data: Data) -> [PaperResult] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else { return [] }
        var results: [PaperResult] = []
        for item in items {
            let type = item["type"] as? String ?? ""
            guard !ignoredTypes.contains(type),
                  let rawTitle = (item["title"] as? [String])?.first, !rawTitle.isEmpty else { continue }
            let authors = (item["author"] as? [[String: Any]] ?? []).compactMap { author -> (given: String, family: String)? in
                if let family = author["family"] as? String {
                    return (clean(author["given"] as? String ?? ""), clean(family))
                }
                if let name = author["name"] as? String { return ("", clean(name)) }
                return nil
            }
            var year = ""
            if let issued = item["issued"] as? [String: Any],
               let parts = issued["date-parts"] as? [[Any]],
               let first = parts.first?.first as? Int {
                year = String(first)
            }
            results.append(PaperResult(
                doi: item["DOI"] as? String ?? "", type: type, title: clean(rawTitle), authors: authors, year: year,
                venue: clean((item["container-title"] as? [String])?.first ?? ""),
                volume: item["volume"] as? String ?? "", issue: item["issue"] as? String ?? "",
                pages: item["page"] as? String ?? "", publisher: clean(item["publisher"] as? String ?? "")))
        }
        return Array(results.prefix(12))
    }

    /// Crossref titles may hold HTML markup and entities.
    private static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// ⇧⌘B: type a paper's title or authors, press return, and it is added to the bibliography.
final class PaperSearchController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((PaperResult) -> Void)?
    /// DOIs and folded titles already in the project, to mark repeated results.
    var isAlreadyAdded: ((PaperResult) -> Bool)?

    private let panel: KeyablePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let footer = NSStackView()
    private var footerActions: [() -> Void] = []
    private var scrollBottom: NSLayoutConstraint!
    private var results: [PaperResult] = []
    private var task: URLSessionDataTask?
    private var debounce: Timer?
    private weak var parent: NSWindow?
    private static let width: CGFloat = 600
    private static let height: CGFloat = 400

    override init() {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        field.placeholderString = L("Título o autores del paper", "Paper title or authors")
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("paper"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
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

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(field)
        background.addSubview(separator)
        background.addSubview(scroll)
        background.addSubview(messageLabel)
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6)
        scrollBottom.isActive = true
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
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            messageLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        panel.contentView = background

        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    /// The buttons at the bottom, for when the search is a step in citing a paper.
    private func setFooter(_ buttons: [(title: String, action: () -> Void)]) {
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footerActions = buttons.map(\.action)
        footer.isHidden = buttons.isEmpty
        scrollBottom.constant = buttons.isEmpty ? -6 : -44
        for (index, item) in buttons.enumerated() {
            let button = NSButton(title: item.title, target: self, action: #selector(footerPressed(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            footer.addArrangedSubview(button)
        }
    }

    @objc private func footerPressed(_ sender: NSButton) {
        guard footerActions.indices.contains(sender.tag) else { return }
        let action = footerActions[sender.tag]
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        chosenByFooter = selected
        dismiss()
        action()
    }

    private var chosenByFooter: PaperResult?

    /// Opens on a search already under way, to confirm which paper this is.
    func show(in window: NSWindow, query: String, buttons: [(title: String, action: () -> Void)]) {
        show(in: window)
        setFooter([(L("Usar el seleccionado", "Use Selected"), { [weak self] in
            if let paper = self?.chosenByFooter { self?.onChoose?(paper) }
        })] + buttons)
        field.stringValue = query
        field.currentEditor()?.selectAll(nil)
        runSearch()
    }

    func show(in window: NSWindow) {
        setFooter([])
        results = []
        table.reloadData()
        field.stringValue = ""
        messageLabel.stringValue = L("Escribí el título, los autores o ambos.", "Type the title, the authors or both.")
        messageLabel.isHidden = false
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
        debounce?.invalidate()
        task?.cancel()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    @objc private func lostFocus() {
        dismiss()
    }

    func controlTextDidChange(_ obj: Notification) {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.runSearch()
        }
    }

    private func runSearch() {
        task?.cancel()
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            results = []
            table.reloadData()
            messageLabel.stringValue = L("Escribí el título, los autores o ambos.", "Type the title, the authors or both.")
            messageLabel.isHidden = false
            return
        }
        messageLabel.stringValue = L("Buscando…", "Searching…")
        messageLabel.isHidden = !results.isEmpty
        task = CrossrefClient.search(query) { [weak self] result in
            guard let self, self.panel.isVisible else { return }
            switch result {
            case .failure(let failure):
                self.results = []
                self.messageLabel.stringValue = failure.message
                self.messageLabel.isHidden = false
            case .success(let papers):
                self.results = papers
                self.messageLabel.stringValue = L("Sin resultados. Probá con menos palabras.", "No results. Try fewer words.")
                self.messageLabel.isHidden = !papers.isEmpty
            }
            self.table.reloadData()
            if !self.results.isEmpty {
                self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                self.table.scrollRowToVisible(0)
            }
        }
    }

    private func choose(_ row: Int) {
        guard results.indices.contains(row) else { return }
        let paper = results[row]
        dismiss()
        onChoose?(paper)
    }

    @objc private func clicked() {
        choose(table.clickedRow)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            choose(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = min(results.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("paper")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(wrappingLabelWithString: "")
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let paper = results[row]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: paper.title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        var detail = paper.detail
        if isAlreadyAdded?(paper) == true { detail = L("Ya está en tu bibliografía · ", "Already in your bibliography · ") + detail }
        text.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        cell.textField?.attributedStringValue = text
        return cell
    }
}

extension ProjectWindowController {
    /// references.bib if it exists; otherwise the project's only .bib that Zotero
    /// does not manage, so as not to scatter references; otherwise a new references.bib.
    private func bibliographyTarget() -> URL {
        let base = mainFile?.deletingLastPathComponent() ?? root
        let conventional = base.appendingPathComponent("references.bib")
        if FileManager.default.fileExists(atPath: conventional.path) { return conventional }
        var candidates: [URL] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "bib", !isZoteroFile(url) { candidates.append(url) }
        }
        return candidates.count == 1 ? candidates[0] : conventional
    }

    private func projectBibText() -> String {
        var combined = ""
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "bib", let data = try? Data(contentsOf: url) {
                combined += String(decoding: data, as: UTF8.self).lowercased() + "\n"
            }
        }
        return combined
    }

    private func isPaper(_ paper: PaperResult, in bibText: String) -> Bool {
        if !paper.doi.isEmpty, bibText.contains(paper.doi.lowercased()) { return true }
        let title = BibParser.fold(paper.title)
        return citationIndex.entries.contains { BibParser.fold($0.title) == title }
    }

    @objc func showPaperSearch(_ sender: Any?) {
        guard let window else { return }
        let bibText = projectBibText()
        paperSearch.isAlreadyAdded = { [weak self] paper in self?.isPaper(paper, in: bibText) ?? false }
        paperSearch.onChoose = { [weak self] paper in self?.addToBibliography(paper) }
        paperSearch.show(in: window)
    }

    /// A key chosen from Jevons's papers: its entry joins this project's bibliography.
    func addFromJevons(key: String) {
        guard !citationIndex.entries.contains(where: { $0.key == key }),
              let paper = JevonsLibrary.shared.papers.first(where: { $0.citeKey == key }), !paper.bibtex.isEmpty else { return }
        let target = bibliographyTarget()
        do {
            var existing = (try? Data(contentsOf: target)) ?? Data()
            let isUTF8 = String(data: existing, encoding: .utf8) != nil
            if !existing.isEmpty, existing.last != 10 { existing.append(10) }
            if !existing.isEmpty { existing.append(10) }
            existing.append(isUTF8 ? Data(paper.bibtex.utf8) : (paper.bibtex.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(paper.bibtex.utf8)))
            try existing.write(to: target, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        citationIndex.reload(root: root)
        syncWithDisk()
        setStatus(L("Agregado a \(target.lastPathComponent): \(key)", "Added to \(target.lastPathComponent): \(key)"), .secondaryLabelColor)
    }

    // MARK: - Completing a paper from Jevons

    /// The search with the paper's title already written, a form for what Crossref doesn't
    /// have and, while citing, the choice of leaving things as they are. What you confirm goes
    /// back to Jevons, so it's only done once.
    func completeJevonsPaper(_ paper: JevonsPaper, keepKey: Bool, citeAnyway: Bool, finish: @escaping (String) -> Void) {
        guard let window else { return }
        let apply: (PaperResult) -> Void = { [weak self] result in
            guard let self else { return }
            finish(self.submitCompletion(of: paper, with: result, keepKey: keepKey))
        }
        paperSearch.isAlreadyAdded = { _ in false }
        paperSearch.onChoose = apply
        var buttons: [(title: String, action: () -> Void)] = [(L("Completar a mano…", "Enter by Hand…"), {
            DispatchQueue.main.async {
                if let result = JevonsManualForm.ask(paper) { apply(result) }
            }
        })]
        if citeAnyway { buttons.append((L("Citar así", "Cite As Is"), { finish(paper.citeKey) })) }
        paperSearch.show(in: window, query: ([paper.title] + paper.authors.prefix(1).map(\.family)).joined(separator: " "), buttons: buttons)
    }

    private func submitCompletion(of paper: JevonsPaper, with result: PaperResult, keepKey: Bool) -> String {
        var key = paper.citeKey
        let projectKeys = Set(citationIndex.entries.map(\.key))
        if !keepKey, !projectKeys.contains(key), !JevonsCitations.isCited(key) {
            let others = JevonsLibrary.shared.papers.filter { $0.path != paper.path }.map(\.citeKey)
            key = result.makeKey(avoiding: projectKeys.union(others))
        }
        JevonsLibrary.shared.submit(JevonsCompletion(
            path: paper.path, title: result.title, authors: result.authors.map { JevonsAuthor(given: $0.given, family: $0.family) },
            year: result.year, venue: result.venue, volume: result.volume, issue: result.issue, pages: result.pages,
            publisher: result.publisher, doi: result.doi, type: result.type, citeKey: key, bibtex: result.bibtex(key: key)))
        return key
    }

    /// The text of a key's entry in this project's own .bib files; Zotero's aren't touched.
    private func bibEntry(key: String) -> (url: URL, range: NSRange, text: NSString)? {
        let pattern = "@[a-zA-Z]+\\s*\\{\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*,"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "bib", !isZoteroFile(url), let data = try? Data(contentsOf: url) else { continue }
            let text = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)) as NSString
            guard let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { continue }
            var depth = 0
            var index = match.range.location
            while index < text.length {
                let unit = text.character(at: index)
                if unit == 123 { depth += 1 }
                if unit == 125 {
                    depth -= 1
                    if depth == 0 { return (url, NSRange(location: match.range.location, length: index + 1 - match.range.location), text) }
                }
                index += 1
            }
        }
        return nil
    }

    /// Hands a citation to Jevons, with its entry as written here.
    func addCitationToJevons(key: String, choosingPDF: Bool, onStarted: () -> Void) {
        guard let entry = citationIndex.entries.first(where: { $0.key == key }) else { return }
        var pdfPath: String?
        if choosingPDF {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.message = L("Elegí el PDF de este paper.", "Choose this paper's PDF.")
            panel.prompt = L("Agregar", "Add")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            pdfPath = url.path
        }
        let raw = bibEntry(key: key).map { $0.text.substring(with: $0.range) }
        if JevonsLibrary.shared.requestAddition(JevonsAddition(entry: entry, rawEntry: raw, pdfPath: pdfPath)) {
            onStarted()
        }
    }

    /// Whether this citation's entry differs from what Jevons now knows about the paper.
    func bibEntryIsStale(key: String, paper: JevonsPaper) -> Bool {
        guard let entry = bibEntry(key: key) else { return false }
        let squeeze = { (text: String) in text.filter { !$0.isWhitespace } }
        return squeeze(entry.text.substring(with: entry.range)) != squeeze(paper.bibtex(usingKey: key))
    }

    /// Puts Jevons's data in this citation's entry, keeping its key so that the text doesn't change.
    func updateBibEntry(key: String, paper: JevonsPaper) {
        saveAll(interactive: true)
        let bibtex = paper.bibtex(usingKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = bibEntry(key: key) else {
            setStatus(L("\(key) no está en un .bib que Walras pueda cambiar", "\(key) isn't in a .bib that Walras can change"), .secondaryLabelColor)
            return
        }
        do {
            try entry.text.replacingCharacters(in: entry.range, with: bibtex).write(to: entry.url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        citationIndex.reload(root: root)
        syncWithDisk()
        setStatus(L("Actualizado en \(entry.url.lastPathComponent): \(key)", "Updated in \(entry.url.lastPathComponent): \(key)"), .secondaryLabelColor)
    }

    private func addToBibliography(_ paper: PaperResult) {
        saveAll(interactive: true)
        let bibText = projectBibText()
        if isPaper(paper, in: bibText) {
            setStatus(L("Esa referencia ya estaba en tu bibliografía", "That reference was already in your bibliography"), .secondaryLabelColor)
            return
        }
        let target = bibliographyTarget()
        let keys = Set(citationIndex.entries.map(\.key))
        let key = paper.makeKey(avoiding: keys)
        let entry = paper.bibtex(key: key)

        do {
            var existing = (try? Data(contentsOf: target)) ?? Data()
            let isUTF8 = String(data: existing, encoding: .utf8) != nil
            if !existing.isEmpty, existing.last != 10 { existing.append(10) }
            if !existing.isEmpty { existing.append(10) }
            let encoded = isUTF8 ? Data(entry.utf8) : (entry.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(entry.utf8))
            existing.append(encoded)
            try existing.write(to: target, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        syncWithDisk()
        setStatus(L("Agregado a \(target.lastPathComponent): \(key)", "Added to \(target.lastPathComponent): \(key)"), .secondaryLabelColor)
        editor.focus()
    }
}
