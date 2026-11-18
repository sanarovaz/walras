import AppKit

/// What a command that takes a file name can point to, and how it wants the name written.
enum ProjectFileKind {
    case tex, graphic, bibliography, bibResource

    var extensions: Set<String> {
        switch self {
        case .tex: return ["tex", "ltx"]
        case .graphic: return ["pdf", "png", "jpg", "jpeg", "eps"]
        case .bibliography, .bibResource: return ["bib"]
        }
    }

    var keepsExtension: Bool { self == .graphic || self == .bibResource }
}

struct CompletionItem {
    /// What the typed text is compared with. An exact match closes the list, so Enter makes a new line.
    let name: String
    let insert: String
    let title: String
    let detail: String
    /// A paper from Jevons whose data still has to be confirmed before citing it.
    var needsData = false
}

enum LatexCatalog {
    /// `{}` marks where each argument goes; the caret lands in the first one.
    static let commands: [String] = [
        "section{}", "section*{}", "subsection{}", "subsection*{}", "subsubsection{}", "paragraph{}", "chapter{}", "part{}",
        "documentclass{}", "usepackage{}", "begin{}", "end{}", "input{}", "include{}", "includegraphics{}",
        "title{}", "author{}", "date{}", "maketitle", "tableofcontents", "appendix", "newpage", "clearpage", "pagebreak",
        "label{}", "ref{}", "eqref{}", "pageref{}", "cite{}", "citep{}", "citet{}", "parencite{}", "textcite{}", "autocite{}",
        "footnote{}", "caption{}", "centering", "item", "noindent", "vspace{}", "hspace{}", "hfill", "vfill", "medskip", "bigskip", "smallskip",
        "textbf{}", "textit{}", "texttt{}", "textsc{}", "emph{}", "underline{}", "text{}", "url{}", "href{}{}",
        "newcommand{}{}", "renewcommand{}{}", "newenvironment{}{}{}", "newtheorem{}{}", "DeclareMathOperator{}{}", "setlength{}{}",
        "bibliography{}", "bibliographystyle{}", "addbibresource{}", "printbibliography",
        "toprule", "midrule", "bottomrule", "cmidrule{}", "hline", "multicolumn{}{}{}", "multirow{}{}{}",
        "frac{}{}", "dfrac{}{}", "tfrac{}{}", "sqrt{}", "sum", "prod", "int", "lim", "max", "min", "sup", "inf", "log", "ln", "exp",
        "partial", "nabla", "infty", "cdot", "cdots", "ldots", "dots", "times", "leq", "geq", "neq", "approx", "equiv", "sim", "propto",
        "in", "notin", "subset", "subseteq", "cup", "cap", "forall", "exists", "to", "rightarrow", "Rightarrow", "leftarrow", "Leftrightarrow", "mapsto",
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "theta", "lambda", "mu", "pi", "rho", "sigma", "tau", "phi", "varphi", "chi", "psi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Pi", "Sigma", "Phi", "Psi", "Omega",
        "mathbb{}", "mathbf{}", "mathcal{}", "mathrm{}", "bar{}", "hat{}", "tilde{}", "overline{}", "underbrace{}", "left", "right", "quad", "qquad",
        "tikz", "draw", "node", "color{}", "textcolor{}{}", "frametitle{}",
    ]

    static let environments: [String] = [
        "document", "abstract", "figure", "figure*", "table", "table*", "tabular", "center", "itemize", "enumerate", "description",
        "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "split", "cases", "matrix", "pmatrix", "bmatrix",
        "theorem", "lemma", "proposition", "corollary", "definition", "proof", "remark", "example",
        "frame", "block", "columns", "column", "tikzpicture", "tcolorbox", "minipage", "quote", "verbatim", "thebibliography",
    ]
}

/// Labels, commands and environments defined in the project's own files.
final class ProjectSymbols {
    struct Label {
        let key: String
        let location: String
        let snippet: String
    }

    private(set) var labels: [Label] = []
    private(set) var ownCommands: [CompletionItem] = []
    private(set) var environmentNames: [String] = []
    private var generation = 0

    private static let labelPattern = try! NSRegularExpression(pattern: "\\\\label\\{([^{}]+)\\}")
    private static let commandPatterns = [
        try! NSRegularExpression(pattern: "\\\\(?:re|provide)?newcommand\\*?\\s*\\{?\\\\([a-zA-Z@]+)\\}?\\s*(?:\\[([0-9])\\])?"),
        try! NSRegularExpression(pattern: "\\\\DeclareMathOperator\\*?\\s*\\{?\\\\([a-zA-Z]+)\\}?"),
        try! NSRegularExpression(pattern: "\\\\DeclarePairedDelimiter\\s*\\{?\\\\([a-zA-Z]+)\\}?"),
        try! NSRegularExpression(pattern: "\\\\def\\\\([a-zA-Z@]+)"),
    ]
    private static let environmentPatterns = [
        try! NSRegularExpression(pattern: "\\\\(?:re)?newenvironment\\*?\\{([a-zA-Z*]+)\\}"),
        try! NSRegularExpression(pattern: "\\\\newtheorem\\*?\\{([a-zA-Z*]+)\\}"),
        try! NSRegularExpression(pattern: "\\\\(?:new|renew|Declare)[tT]colorbox(?:\\[[^\\]]*\\])?\\{([a-zA-Z*]+)\\}"),
    ]

    func reload(root: URL) {
        generation += 1
        let current = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Self.scan(root: root)
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.labels = found.labels
                self.ownCommands = found.commands
                self.environmentNames = found.environments
            }
        }
    }

    private static func scan(root: URL) -> (labels: [Label], commands: [CompletionItem], environments: [String]) {
        var labels: [Label] = []
        var commands: [String: CompletionItem] = [:]
        var environments = Set<String>()
        let base = root.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            guard ["tex", "ltx", "sty", "cls"].contains(url.pathExtension.lowercased()),
                  let data = try? Data(contentsOf: url), data.count < 5_000_000 else { continue }
            let string = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let text = string as NSString
            let full = NSRange(location: 0, length: text.length)
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent

            for match in labelPattern.matches(in: string, options: [], range: full) {
                let lineRange = text.lineRange(for: match.range)
                let number = text.substring(to: lineRange.location).utf16.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
                let snippet = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                labels.append(Label(key: text.substring(with: match.range(at: 1)),
                                    location: "\(relative):\(number)", snippet: String(snippet.prefix(80))))
            }
            for pattern in commandPatterns {
                for match in pattern.matches(in: string, options: [], range: full) {
                    let name = text.substring(with: match.range(at: 1))
                    var count = 0
                    if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                        count = Int(text.substring(with: match.range(at: 2))) ?? 0
                    }
                    let template = name + String(repeating: "{}", count: count)
                    commands[name] = CompletionItem(name: name, insert: template, title: "\\" + template,
                                                    detail: L("Definido en \(relative)", "Defined in \(relative)"))
                }
            }
            for pattern in environmentPatterns {
                for match in pattern.matches(in: string, options: [], range: full) {
                    environments.insert(text.substring(with: match.range(at: 1)))
                }
            }
        }
        labels.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return (labels, Array(commands.values), Array(environments))
    }

    func labelItems(matching query: String) -> [CompletionItem] {
        let tokens = BibParser.fold(query).split(separator: " ").map(String.init)
        let hits = labels.filter { label in
            let haystack = BibParser.fold(label.key + " " + label.snippet)
            return tokens.allSatisfy { haystack.contains($0) }
        }
        return hits.prefix(40).map {
            CompletionItem(name: $0.key, insert: $0.key, title: $0.key, detail: "\($0.location) · \($0.snippet)")
        }
    }

    func commandItems(matching query: String) -> [CompletionItem] {
        let ownNames = Set(ownCommands.map(\.name))
        let builtIn = LatexCatalog.commands.compactMap { template -> CompletionItem? in
            let name = template.components(separatedBy: "{").first ?? template
            if ownNames.contains(name) { return nil }
            return CompletionItem(name: name, insert: template, title: "\\" + template, detail: "")
        }
        return Array((Self.rank(ownCommands, query) + Self.rank(builtIn, query)).prefix(40))
    }

    func environmentItems(matching query: String) -> [CompletionItem] {
        let own = environmentNames.map {
            CompletionItem(name: $0, insert: $0, title: $0, detail: L("Definido en el proyecto", "Defined in the project"))
        }
        let ownNames = Set(environmentNames)
        let builtIn = LatexCatalog.environments.filter { !ownNames.contains($0) }.map {
            CompletionItem(name: $0, insert: $0, title: $0, detail: "")
        }
        return Array((Self.rank(own, query) + Self.rank(builtIn, query)).prefix(40))
    }

    /// Names that start with the text come first, then names that merely contain it.
    private static func rank(_ items: [CompletionItem], _ query: String) -> [CompletionItem] {
        let folded = query.lowercased()
        let prefixed = items.filter { $0.name.lowercased().hasPrefix(folded) }
        let contained = items.filter { !$0.name.lowercased().hasPrefix(folded) && $0.name.lowercased().contains(folded) }
        return prefixed.sorted { $0.name.count < $1.name.count } + contained
    }
}

/// The floating list used for every kind of completion. The panel never takes
/// the keyboard: the editor keeps it and forwards arrows, return and escape.
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onAccept: ((CompletionItem) -> Void)?

    private let panel: NSPanel
    private let table = NSTableView()
    private var items: [CompletionItem] = []
    private weak var parent: NSWindow?
    private static let rowHeight: CGFloat = 38
    private static let width: CGFloat = 480

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ entries: [CompletionItem], caret: NSRect, in window: NSWindow) {
        items = entries
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)

        let height = min(CGFloat(entries.count), 6) * (Self.rowHeight + 2) + 12
        var origin = NSPoint(x: caret.minX, y: caret.minY - height - 4)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = caret.maxY + 4 }
            origin.x = min(origin.x, screen.maxX - Self.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(items.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func acceptSelection() {
        guard items.indices.contains(table.selectedRow) else { return }
        onAccept?(items[table.selectedRow])
    }

    @objc private func clicked(_ sender: Any?) {
        guard items.indices.contains(table.clickedRow) else { return }
        onAccept?(items[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("completion")
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
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let item = items[row]
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if !item.detail.isEmpty {
            text.append(NSAttributedString(string: "\n" + item.detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        cell.textField?.attributedStringValue = text
        return cell
    }
}
