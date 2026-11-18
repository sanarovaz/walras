import AppKit

/// What Walras reads from Jevons, the paper library. Nothing here writes to it,
/// apart from the list of where each project cites what.
struct JevonsHighlight: Decodable {
    let id: String
    let page: Int
    let text: String
    let note: String
}

struct JevonsAuthor: Codable {
    let given: String
    let family: String
}

/// Data confirmed in Walras, left for Jevons to pick up, even if it's closed right now.
struct JevonsCompletion: Codable {
    let path: String
    let title: String
    let authors: [JevonsAuthor]
    let year: String
    let venue: String
    let volume: String
    let issue: String
    let pages: String
    let publisher: String
    let doi: String
    let type: String
    let citeKey: String
    let bibtex: String
}

/// A citation to add to Jevons, with the data it already has in the project.
struct JevonsAddition: Encodable {
    let citeKey: String
    let title: String
    let authors: [JevonsAuthor]
    let year: String
    let venue: String
    let volume: String
    let issue: String
    let pages: String
    let publisher: String
    let doi: String
    let type: String
    let bibtex: String?
    let pdfPath: String?

    init(entry: BibEntry, rawEntry: String?, pdfPath: String?) {
        let fields = entry.fields
        citeKey = entry.key
        title = entry.title
        year = entry.year
        venue = fields["journal"] ?? fields["journaltitle"] ?? fields["booktitle"] ?? fields["institution"] ?? ""
        volume = fields["volume"] ?? ""
        issue = fields["number"] ?? ""
        pages = (fields["pages"] ?? "").replacingOccurrences(of: "–", with: "-")
        publisher = fields["publisher"] ?? ""
        doi = fields["doi"] ?? ""
        if fields["journal"] != nil || fields["journaltitle"] != nil { type = "journal-article" }
        else if fields["booktitle"] != nil { type = "book-chapter" }
        else if fields["institution"] != nil { type = "report" }
        else if fields["publisher"] != nil { type = "book" }
        else { type = "other" }
        authors = (fields["author"] ?? fields["editor"] ?? "").components(separatedBy: " and ").compactMap { person in
            let name = person.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if let comma = name.firstIndex(of: ",") {
                return JevonsAuthor(given: name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces), family: String(name[..<comma]))
            }
            let words = name.split(separator: " ").map(String.init)
            return JevonsAuthor(given: words.dropLast().joined(separator: " "), family: words.last ?? name)
        }
        bibtex = rawEntry
        self.pdfPath = pdfPath
    }
}

struct JevonsPaper: Decodable {
    let path: String
    var title: String
    var authors: [JevonsAuthor]
    var year: String
    var venue: String
    var volume: String
    var issue: String
    var pages: String
    var publisher: String
    var doi: String
    var type: String
    var citeKey: String
    let note: String
    let highlights: [JevonsHighlight]
    var bibtex: String
    var verified: Bool?
    var aliases: [String]?

    var isComplete: Bool {
        if verified == true { return true }
        return !doi.isEmpty && !authors.isEmpty && !year.isEmpty && (!venue.isEmpty || type.contains("book") || type == "monograph")
    }

    /// The entry with the key a project uses for this paper, which can differ from Jevons's.
    func bibtex(usingKey key: String) -> String {
        guard let open = bibtex.firstIndex(of: "{"), let comma = bibtex.firstIndex(of: ",") else { return bibtex }
        return bibtex.replacingCharacters(in: bibtex.index(after: open)..<comma, with: key)
    }

    var authorLine: String {
        let names = authors.map(\.family)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return L("\(names[0]) y \(names[1])", "\(names[0]) and \(names[1])")
        default: return "\(names[0]) et al."
        }
    }

    var summary: String {
        let who = year.isEmpty ? authorLine : "\(authorLine) (\(year))"
        return who.isEmpty ? title : "\(who) · \(title)"
    }

    var searchText: String { BibParser.fold("\(citeKey) \(authors.map(\.family).joined(separator: " ")) \(year) \(title)") }
}

final class JevonsLibrary {
    static let shared = JevonsLibrary()

    private struct Contents: Decodable {
        let papers: [JevonsPaper]
    }

    private(set) var papers: [JevonsPaper] = []
    private var loadedDate: Date?

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Jevons", isDirectory: true)
    }

    /// Reads the file again only if Jevons changed it.
    func refresh() {
        if let url = Self.folder?.appendingPathComponent("library.json"),
           let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           date != loadedDate, let data = try? Data(contentsOf: url),
           let contents = try? JSONDecoder().decode(Contents.self, from: data) {
            loadedDate = date
            papers = contents.papers.filter { !$0.citeKey.isEmpty }
        }
        applyWaiting()
    }

    private static var completionsFolder: URL? { folder?.appendingPathComponent("completions", isDirectory: true) }

    /// Completions Jevons hasn't picked up yet count already.
    private func applyWaiting() {
        guard let folder = Self.completionsFolder else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let item = try? JSONDecoder().decode(JevonsCompletion.self, from: data) { merge(item) }
        }
    }

    private func merge(_ item: JevonsCompletion) {
        guard let index = papers.firstIndex(where: { $0.path == item.path }) else { return }
        var paper = papers[index]
        if paper.citeKey != item.citeKey { paper.aliases = (paper.aliases ?? []) + [paper.citeKey] }
        paper.title = item.title; paper.authors = item.authors; paper.year = item.year; paper.venue = item.venue
        paper.volume = item.volume; paper.issue = item.issue; paper.pages = item.pages; paper.publisher = item.publisher
        paper.doi = item.doi; paper.type = item.type; paper.citeKey = item.citeKey; paper.bibtex = item.bibtex; paper.verified = true
        papers[index] = paper
    }

    static var isInstalled: Bool {
        guard let probe = URL(string: "jevons://open") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    /// Leaves the request in Jevons's folder and wakes it up without bringing it to the front.
    func requestAddition(_ addition: JevonsAddition) -> Bool {
        guard let folder = Self.folder?.appendingPathComponent("additions", isDirectory: true),
              let data = try? JSONEncoder().encode(addition) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        guard (try? data.write(to: folder.appendingPathComponent(id + ".json"), options: .atomic)) != nil,
              let url = URL(string: "jevons://add?id=\(id)") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
        return true
    }

    func submit(_ item: JevonsCompletion) {
        merge(item)
        guard let folder = Self.completionsFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(item) else { return }
        try? data.write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.sanarovaz.jevons.completed"),
                                                                     object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// A citation can use another key than Jevons's, so a paper is also recognised by its title.
    func paper(forCitation key: String, entries: [BibEntry]) -> JevonsPaper? {
        refresh()
        if let exact = papers.first(where: { $0.citeKey == key || $0.aliases?.contains(key) == true }) { return exact }
        guard let entry = entries.first(where: { $0.key == key }) else { return nil }
        let title = BibParser.fold(entry.title)
        guard !title.isEmpty else { return nil }
        return papers.first { BibParser.fold($0.title) == title }
    }

    /// Papers in Jevons that this project doesn't have in its bibliography yet.
    func completions(matching query: String, excluding entries: [BibEntry]) -> [JevonsPaper] {
        refresh()
        let keys = Set(entries.map(\.key))
        let titles = Set(entries.map { BibParser.fold($0.title) })
        let tokens = BibParser.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return papers.filter { paper in
            FileManager.default.fileExists(atPath: paper.path)
                && !keys.contains(paper.citeKey) && !titles.contains(BibParser.fold(paper.title))
                && tokens.allSatisfy { paper.searchText.contains($0) }
        }.sorted { $0.citeKey < $1.citeKey }
    }

    static func link(key: String, highlight: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "jevons"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        if let highlight { components.queryItems?.append(URLQueryItem(name: "highlight", value: highlight)) }
        return components.url
    }
}

/// Tells Jevons where each project cites what, for its "Cited In" tab.
enum JevonsCitations {
    private struct Place: Codable {
        let file: String
        let line: Int
    }

    private struct Project: Encodable {
        let root: String
        let name: String
        let keys: [String: [Place]]
    }

    private static let pattern = try! NSRegularExpression(pattern: "\\\\[a-zA-Z]*[cC]ite[a-zA-Z]*\\*?(?:\\[[^\\]\\n]*\\])*\\{([^{}\\n]*)\\}")
    private static var timer: Timer?

    private struct CitedKeys: Decodable {
        let keys: [String: [Place]]
    }

    /// Whether any project already cites this key, in which case it must not change.
    static func isCited(_ key: String) -> Bool {
        guard let folder = JevonsLibrary.folder?.appendingPathComponent("citations", isDirectory: true) else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.contains { file in
            guard let data = try? Data(contentsOf: file), let project = try? JSONDecoder().decode(CitedKeys.self, from: data) else { return false }
            return project.keys[key]?.isEmpty == false
        }
    }

    static func schedule(root: URL, entries: [BibEntry]) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            JevonsLibrary.shared.refresh()
            let papers = JevonsLibrary.shared.papers
            DispatchQueue.global(qos: .utility).async { write(root: root, entries: entries, papers: papers) }
        }
    }

    private static func write(root: URL, entries: [BibEntry], papers: [JevonsPaper]) {
        guard let folder = JevonsLibrary.folder, FileManager.default.fileExists(atPath: folder.path) else { return }
        let base = root.standardizedFileURL.path + "/"
        var titleToKey: [String: String] = [:]
        for paper in papers { titleToKey[BibParser.fold(paper.title)] = paper.citeKey }
        var aliases: [String: String] = [:]
        for entry in entries {
            if let key = titleToKey[BibParser.fold(entry.title)], key != entry.key { aliases[entry.key] = key }
        }
        var keys: [String: [Place]] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "tex", let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let path = url.standardizedFileURL.path
            let file = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            for (index, line) in text.components(separatedBy: .newlines).enumerated() where line.contains("ite") {
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let group = Range(match.range(at: 1), in: line) else { continue }
                    for raw in line[group].split(separator: ",") {
                        let key = raw.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { continue }
                        keys[aliases[key] ?? key, default: []].append(Place(file: file, line: index + 1))
                    }
                }
            }
        }
        let output = folder.appendingPathComponent("citations", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_") + ".json"
        let project = Project(root: root.standardizedFileURL.path, name: root.lastPathComponent, keys: keys)
        if let data = try? JSONEncoder().encode(project) { try? data.write(to: output.appendingPathComponent(name), options: .atomic) }
    }
}

/// A row in the code column, like Claude's, opened by ⌘-clicking a citation:
/// what Jevons has on that paper, and arrows to go through the others the file cites.
final class JevonsNotesViewController: NSViewController, NSTextViewDelegate {
    var entries: () -> [BibEntry] = { [] }
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onHide: (() -> Void)?
    var onComplete: (() -> Void)?
    var onAdd: ((_ choosingPDF: Bool) -> Void)?
    private var addingKey: String?
    var onUpdateBib: (() -> Void)?
    var isBibStale: ((String, JevonsPaper) -> Bool)?
    private(set) var currentKey: String?
    private var textView: NSTextView!
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let hideButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "")

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    override func loadView() {
        let root = ThemedBackgroundView { $0.sidebar }
        configure(previousButton, symbol: "chevron.left", tip: L("Paper citado anterior", "Previous cited paper"), action: #selector(previousPressed))
        configure(nextButton, symbol: "chevron.right", tip: L("Paper citado siguiente", "Next cited paper"), action: #selector(nextPressed))
        configure(hideButton, symbol: "xmark", tip: L("Esconder", "Hide"), action: #selector(hidePressed))
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 10, height: 2)
        text.delegate = self
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        for subview in [previousButton, positionLabel, nextButton, hideButton, scroll] as [NSView] { root.addSubview(subview) }
        NSLayoutConstraint.activate([
            previousButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            previousButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            previousButton.widthAnchor.constraint(equalToConstant: 22),
            previousButton.heightAnchor.constraint(equalToConstant: 22),
            positionLabel.centerYAnchor.constraint(equalTo: previousButton.centerYAnchor),
            positionLabel.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 4),
            nextButton.centerYAnchor.constraint(equalTo: previousButton.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 4),
            nextButton.widthAnchor.constraint(equalToConstant: 22),
            nextButton.heightAnchor.constraint(equalToConstant: 22),
            hideButton.centerYAnchor.constraint(equalTo: previousButton.centerYAnchor),
            hideButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hideButton.widthAnchor.constraint(equalToConstant: 22),
            hideButton.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: previousButton.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        textView = text
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .editorThemeChanged, object: nil)
        render()
    }

    @objc private func previousPressed() { onPrevious?() }
    @objc private func nextPressed() { onNext?() }
    @objc private func hidePressed() { onHide?() }

    @objc private func themeChanged() {
        view.needsDisplay = true
        render()
    }

    func show(key: String) {
        currentKey = key
        if isViewLoaded { render() }
    }

    /// "2 of 7" between the arrows, which stop working at the ends.
    func setPosition(index: Int?, count: Int) {
        _ = view
        positionLabel.stringValue = index.map { L("\($0 + 1) de \(count)", "\($0 + 1) of \(count)") } ?? ""
        previousButton.isEnabled = (index ?? 1) > 0
        nextButton.isEnabled = (index ?? -1) < count - 1
    }

    func showAdding() {
        addingKey = currentKey
        if isViewLoaded { render() }
    }

    /// When the app comes back from Jevons, new notes should appear.
    func refresh() {
        addingKey = nil
        if isViewLoaded { render() }
    }

    private func render() {
        guard let textView else { return }
        let theme = EditorTheme.current
        positionLabel.textColor = theme.comment
        for button in [previousButton, nextButton, hideButton] { button.contentTintColor = theme.icon }
        let out = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor, link: URL? = nil, after: CGFloat = 6, indent: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
            ]
            if let link {
                attributes[.link] = link
                attributes[.cursor] = NSCursor.pointingHand
            }
            out.append(NSAttributedString(string: text + "\n", attributes: attributes))
        }
        textView.linkTextAttributes = [.foregroundColor: theme.accent, .cursor: NSCursor.pointingHand]

        guard let key = currentKey else {
            textView.textStorage?.setAttributedString(out)
            return
        }
        guard let paper = JevonsLibrary.shared.paper(forCitation: key, entries: entries()) else {
            add(key, size: 13, weight: .semibold, color: theme.text, after: 2)
            if let entry = entries().first(where: { $0.key == key }) { add(entry.summary, size: 11, color: theme.comment, after: 8) }
            add(L("Este paper no está en Jevons.", "This paper isn't in Jevons."), color: theme.comment, after: 8)
            if addingKey == key {
                add(L("Buscando el PDF…", "Looking for the PDF…"), size: 11, color: theme.comment)
            } else if JevonsLibrary.isInstalled, entries().contains(where: { $0.key == key }) {
                add(L("Agregar a Jevons", "Add to Jevons"), size: 12, weight: .medium, color: theme.accent, link: URL(string: "walras-row://add"), after: 3)
                add(L("Agregar con un PDF de esta Mac…", "Add with a PDF from this Mac…"), size: 11, color: theme.accent, link: URL(string: "walras-row://addpdf"))
            }
            textView.textStorage?.setAttributedString(out)
            return
        }
        add(paper.title, size: 13, weight: .semibold, color: theme.text, after: 2)
        add(paper.authorLine + (paper.year.isEmpty ? "" : " (\(paper.year))"), size: 11, color: theme.comment, after: 2)
        add(L("Abrir en Jevons", "Open in Jevons"), size: 11, color: theme.accent, link: JevonsLibrary.link(key: paper.citeKey), after: 2)
        add(paper.isComplete ? L("Corregir datos", "Fix data") : L("Datos incompletos: completar", "Incomplete data: complete"),
            size: 11, color: theme.accent, link: URL(string: "walras-row://complete"), after: 2)
        if paper.isComplete, isBibStale?(key, paper) == true {
            add(L("Actualizar la entrada del .bib con estos datos", "Update the .bib entry with this data"), size: 11, color: theme.accent,
                link: URL(string: "walras-row://updatebib"), after: 2)
        }
        add("", size: 4, color: theme.comment, after: 4)
        if !paper.note.isEmpty { add(paper.note, color: theme.text, after: 12) }
        let sorted = paper.highlights.sorted { $0.page < $1.page }
        for highlight in sorted {
            let quote = highlight.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            add("p. \(highlight.page + 1)", size: 10, weight: .medium, color: theme.accent,
                link: JevonsLibrary.link(key: paper.citeKey, highlight: highlight.id), after: 1)
            add(quote, size: 11, color: theme.comment, after: highlight.note.isEmpty ? 10 : 3, indent: 8)
            if !highlight.note.isEmpty { add(highlight.note, color: theme.text, after: 10, indent: 8) }
        }
        if paper.note.isEmpty, sorted.isEmpty {
            add(L("Todavía no tenés notas de este paper.", "You have no notes on this paper yet."), color: theme.comment)
        }
        textView.textStorage?.setAttributedString(out)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return true }
        switch url.scheme == "walras-row" ? url.host : nil {
        case "complete": onComplete?()
        case "add": onAdd?(false)
        case "addpdf": onAdd?(true)
        case "updatebib": onUpdateBib?()
        default: NSWorkspace.shared.open(url)
        }
        return true
    }
}

/// The form for what Crossref doesn't have, such as many working papers.
enum JevonsManualForm {
    private static let types: [(title: String, type: String)] = [
        (L("Artículo", "Article"), "journal-article"), ("Working paper", "report"), (L("Libro", "Book"), "book"),
        (L("Capítulo", "Chapter"), "book-chapter"), (L("Otro", "Other"), "other"),
    ]

    static func ask(_ paper: JevonsPaper) -> PaperResult? {
        func input(_ value: String) -> NSTextField {
            let field = NSTextField(string: value)
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
            return field
        }
        let title = input(paper.title)
        let authors = input(paper.authors.map { $0.given.isEmpty ? $0.family : "\($0.family), \($0.given)" }.joined(separator: "; "))
        authors.placeholderString = L("Apellido, Nombre; Apellido, Nombre", "Family, Given; Family, Given")
        let year = input(paper.year), venue = input(paper.venue), volume = input(paper.volume), issue = input(paper.issue)
        let pages = input(paper.pages), publisher = input(paper.publisher), doi = input(paper.doi)
        let type = NSPopUpButton()
        types.forEach { type.addItem(withTitle: $0.title) }
        type.selectItem(at: types.firstIndex { $0.type == paper.type } ?? 0)
        let rows: [(String, NSView)] = [
            (L("Tipo", "Type"), type), (L("Título", "Title"), title), (L("Autores", "Authors"), authors), (L("Año", "Year"), year),
            (L("Revista o institución", "Journal or institution"), venue), (L("Volumen", "Volume"), volume), (L("Número", "Number"), issue),
            (L("Páginas", "Pages"), pages), (L("Editorial", "Publisher"), publisher), ("DOI", doi),
        ]
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.layoutSubtreeIfNeeded()
        grid.frame.size = grid.fittingSize
        let alert = NSAlert()
        alert.messageText = L("Datos del paper", "Paper Data")
        alert.accessoryView = grid
        alert.addButton(withTitle: L("Guardar", "Save"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        func trimmed(_ field: NSTextField) -> String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let people: [(given: String, family: String)] = trimmed(authors).split(separator: ";").compactMap { part in
            let pieces = part.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let family = pieces.first, !family.isEmpty else { return nil }
            return (pieces.count > 1 ? pieces[1] : "", family)
        }
        return PaperResult(doi: trimmed(doi), type: types[max(0, type.indexOfSelectedItem)].type, title: trimmed(title), authors: people,
                           year: trimmed(year), venue: trimmed(venue), volume: trimmed(volume), issue: trimmed(issue),
                           pages: trimmed(pages), publisher: trimmed(publisher))
    }
}
