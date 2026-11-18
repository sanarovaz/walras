import AppKit
import CoreServices

// MARK: - Watching the project folder

/// Tells Walras as soon as anything inside the project folder changes.
final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(root: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let matters = changed.contains { path in
                !path.contains("/.git/") && !path.hasSuffix("/.git") && !path.hasSuffix("/.DS_Store")
            }
            if matters { watcher.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

// MARK: - Version store

/// Automatic copies of each text file, kept in Application Support and never in the project.
/// Versions from the last day are all kept; older ones thin out to one per hour, then one per
/// day. Past the size limit the oldest go first, whatever their file, but each file keeps its newest.
final class VersionHistory {
    struct Version {
        let date: Date
        let url: URL
    }

    private let root: URL
    private let folder: URL
    private var lastRecorded: [String: Date] = [:]
    private static let maximumBytes = 100_000_000

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    init(root: URL) {
        self.root = root
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let key = root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
        folder = support.appendingPathComponent("Walras/History/\(key)", isDirectory: true)
    }

    private func relativePath(_ url: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    private func encode(_ relative: String) -> String {
        relative.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? relative
    }

    private func directory(for url: URL) -> URL {
        folder.appendingPathComponent(encode(relativePath(url)), isDirectory: true)
    }

    func versions(of url: URL) -> [Version] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(for: url).path)) ?? []
        return names.compactMap { name -> Version? in
            guard let date = Self.formatter.date(from: name) else { return nil }
            return Version(date: date, url: directory(for: url).appendingPathComponent(name))
        }.sorted { $0.date > $1.date }
    }

    /// `data` lets a caller preserve text that isn't on disk. Identical content is never stored twice.
    func record(_ url: URL, data: Data? = nil, minimumInterval: TimeInterval = 0) {
        let key = url.standardizedFileURL.path
        let now = Date()
        if let last = lastRecorded[key], now.timeIntervalSince(last) < minimumInterval { return }
        guard let content = data ?? (try? Data(contentsOf: url)) else { return }
        let existing = versions(of: url)
        if let latest = existing.first, (try? Data(contentsOf: latest.url)) == content {
            lastRecorded[key] = now
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory(for: url), withIntermediateDirectories: true)
            try content.write(to: directory(for: url).appendingPathComponent(Self.formatter.string(from: now)), options: .atomic)
            lastRecorded[key] = now
        } catch {
            return
        }
        thin(existing, now: now)
        enforceSizeLimit()
    }

    private func enforceSizeLimit() {
        let fm = FileManager.default
        var total = 0
        var removable: [(date: Date, url: URL, size: Int)] = []
        for directory in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            var copies: [(date: Date, url: URL, size: Int)] = []
            for name in names {
                guard let date = Self.formatter.date(from: name) else { continue }
                let url = directory.appendingPathComponent(name)
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                total += size
                copies.append((date, url, size))
            }
            copies.sort { $0.date > $1.date }
            removable += copies.dropFirst()
        }
        guard total > Self.maximumBytes else { return }
        for copy in removable.sorted(by: { $0.date < $1.date }) {
            guard total > Self.maximumBytes else { return }
            if (try? fm.removeItem(at: copy.url)) != nil { total -= copy.size }
        }
    }

    private func thin(_ versions: [Version], now: Date) {
        var seenBuckets = Set<Int>()
        for version in versions {
            let age = now.timeIntervalSince(version.date)
            if age < 86_400 { continue }
            let span: TimeInterval = age < 30 * 86_400 ? 3_600 : 86_400
            let bucket = Int(version.date.timeIntervalSince1970 / span)
            if !seenBuckets.insert(bucket).inserted {
                try? FileManager.default.removeItem(at: version.url)
            }
        }
    }

    /// Versions follow a file or folder when it is renamed or moved inside the project.
    func moved(from old: URL, to new: URL) {
        let oldRelative = relativePath(old)
        let newRelative = relativePath(new)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            guard let decoded = name.removingPercentEncoding else { continue }
            guard decoded == oldRelative || decoded.hasPrefix(oldRelative + "/") else { continue }
            let target = newRelative + decoded.dropFirst(oldRelative.count)
            try? FileManager.default.moveItem(at: folder.appendingPathComponent(name),
                                              to: folder.appendingPathComponent(encode(target)))
        }
    }

    static func text(of data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }
}

// MARK: - History window

final class HistorySheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let diffView: NSTextView
    private let restoreButton: NSButton
    private let versions: [VersionHistory.Version]
    private let currentText: String
    private let onRestore: (String) -> Void
    private let onClose: () -> Void
    private weak var parent: NSWindow?
    private var selectedText: String?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(fileName: String, versions: [VersionHistory.Version], currentText: String,
         onRestore: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.versions = versions
        self.currentText = currentText
        self.onRestore = onRestore
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let diffScroll = NSTextView.scrollableTextView()
        diffView = diffScroll.documentView as! NSTextView
        restoreButton = NSButton(title: L("Restaurar esta versión", "Restore This Version"), target: nil, action: nil)
        super.init()

        panel.minSize = NSSize(width: 620, height: 360)
        panel.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: L("Historial de \(fileName)", "History of \(fileName)"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let legend = NSTextField(labelWithString: L(
            "Rojo: está en tu texto actual y no en esa versión. Verde: está en esa versión y no en tu texto actual.",
            "Red: in your current text but not in that version. Green: in that version but not in your current text."))
        legend.font = .systemFont(ofSize: 11)
        legend.textColor = .secondaryLabelColor
        legend.lineBreakMode = .byTruncatingTail
        legend.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        column.resizingMask = .autoresizingMask
        column.width = 186
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        diffView.isEditable = false
        diffView.isRichText = true
        diffView.textContainerInset = NSSize(width: 8, height: 8)
        diffScroll.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: L("Cerrar", "Close"), target: self, action: #selector(closePressed))
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.target = self
        restoreButton.action = #selector(restorePressed)
        restoreButton.keyEquivalent = "\r"
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [title, legend, tableScroll, diffScroll, closeButton, restoreButton] as [NSView] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            legend.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            legend.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            tableScroll.topAnchor.constraint(equalTo: legend.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tableScroll.widthAnchor.constraint(equalToConstant: 210),
            tableScroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),
            diffScroll.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            diffScroll.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 10),
            diffScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            diffScroll.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            restoreButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            restoreButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            closeButton.trailingAnchor.constraint(equalTo: restoreButton.leadingAnchor, constant: -8),
            closeButton.bottomAnchor.constraint(equalTo: restoreButton.bottomAnchor),
        ])
        panel.contentView = content
    }

    func show(in window: NSWindow) {
        parent = window
        table.reloadData()
        if !versions.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        refreshDiff()
        window.beginSheet(panel, completionHandler: nil)
    }

    private func dismiss() {
        parent?.endSheet(panel)
        panel.orderOut(nil)
        onClose()
    }

    @objc private func closePressed() {
        dismiss()
    }

    @objc private func restorePressed() {
        guard let selectedText else { return }
        let text = selectedText
        dismiss()
        onRestore(text)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { versions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("version")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = .systemFont(ofSize: 12)
        }
        cell.stringValue = Self.dateFormatter.string(from: versions[row].date)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshDiff()
    }

    private func refreshDiff() {
        guard versions.indices.contains(table.selectedRow),
              let data = try? Data(contentsOf: versions[table.selectedRow].url) else {
            selectedText = nil
            restoreButton.isEnabled = false
            diffView.textStorage?.setAttributedString(NSAttributedString(
                string: L("Todavía no hay versiones guardadas de este archivo.", "There are no saved versions of this file yet."),
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
            return
        }
        let text = VersionHistory.text(of: data)
        selectedText = text
        restoreButton.isEnabled = text != currentText
        diffView.textStorage?.setAttributedString(Self.diff(current: currentText, version: text))
        diffView.scrollToBeginningOfDocument(nil)
    }

    /// Only the changed lines and three lines around them.
    private static func diff(current: String, version: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        func plain(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        }
        if current == version { return plain(L("Esta versión es igual a tu texto actual.", "This version is identical to your current text.")) }
        let old = current.components(separatedBy: "\n")
        let new = version.components(separatedBy: "\n")
        guard old.count + new.count < 60_000 else {
            return plain(L("El archivo es demasiado largo para mostrar las diferencias, pero se puede restaurar.",
                           "The file is too long to show differences, but it can be restored."))
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [(kind: Int, text: String)] = [] // -1 removed, 0 same, 1 added
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                rows.append((-1, old[i]))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                rows.append((1, new[j]))
                j += 1
            } else {
                if i < old.count { rows.append((0, old[i])) }
                i += 1
                j += 1
            }
        }

        var keep = Set<Int>()
        for (index, row) in rows.enumerated() where row.kind != 0 {
            for near in max(0, index - 3)...min(rows.count - 1, index + 3) { keep.insert(near) }
        }
        let result = NSMutableAttributedString()
        var skipped = false
        for (index, row) in rows.enumerated() {
            guard keep.contains(index) else {
                skipped = true
                continue
            }
            if skipped {
                result.append(NSAttributedString(string: "⋯\n", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
                skipped = false
            }
            let sign = row.kind == -1 ? "− " : (row.kind == 1 ? "+ " : "  ")
            let color: NSColor = row.kind == -1 ? .systemRed : (row.kind == 1 ? .systemGreen : .secondaryLabelColor)
            result.append(NSAttributedString(string: sign + row.text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}

// MARK: - Window integration

extension ProjectWindowController {
    @objc func showVersionHistory(_ sender: Any?) {
        guard let window, let buffer = editor.current else { return }
        saveAll(interactive: false)
        history.record(buffer.url)
        let sheet = HistorySheetController(
            fileName: buffer.url.lastPathComponent, versions: history.versions(of: buffer.url),
            currentText: buffer.storage.string,
            onRestore: { [weak self] text in self?.restoreVersion(text, of: buffer.url) },
            onClose: { [weak self] in self?.historySheet = nil })
        historySheet = sheet
        sheet.show(in: window)
    }

    private func restoreVersion(_ text: String, of url: URL) {
        history.record(url)
        open(url)
        editor.replaceAllText(with: text)
        setStatus(L("Versión restaurada · ⌘Z para deshacer", "Version restored · ⌘Z to undo"), .secondaryLabelColor)
    }

    func replaceInProject(_ query: String, with replacement: String, files: [URL]) {
        guard let window else { return }
        saveAll(interactive: true)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var changes: [(url: URL, text: String, encoding: String.Encoding)] = []
        var total = 0
        for url in files where !isZoteroFile(url) {
            if buffers[url.standardizedFileURL.path]?.dirty == true { continue }
            guard let data = try? Data(contentsOf: url), data.count < 5_000_000, !data.contains(0) else { continue }
            let encoding: String.Encoding = String(data: data, encoding: .utf8) != nil ? .utf8 : .windowsCP1252
            guard let text = String(data: data, encoding: encoding) else { continue }
            var count = 0
            var range = text.startIndex..<text.endIndex
            while let found = text.range(of: query, options: options, range: range) {
                count += 1
                range = found.upperBound..<text.endIndex
            }
            guard count > 0 else { continue }
            total += count
            changes.append((url, text.replacingOccurrences(of: query, with: replacement, options: options), encoding))
        }
        guard !changes.isEmpty else {
            setStatus(L("No hay nada para reemplazar", "Nothing to replace"), .secondaryLabelColor)
            return
        }

        let alert = NSAlert()
        alert.messageText = L("¿Reemplazar \(total) \(total == 1 ? "coincidencia" : "coincidencias") en \(changes.count) \(changes.count == 1 ? "archivo" : "archivos")?",
                              "Replace \(total) \(total == 1 ? "match" : "matches") in \(changes.count) \(changes.count == 1 ? "file" : "files")?")
        alert.informativeText = L("“\(query)” pasa a ser “\(replacement)”, sin distinguir mayúsculas ni acentos. ⌘Z no lo deshace, pero antes se guarda una copia de cada archivo en el historial de versiones.",
                                  "“\(query)” becomes “\(replacement)”, ignoring case and accents. ⌘Z won't undo this, but a copy of each file is saved to Version History first.")
        alert.addButton(withTitle: L("Reemplazar", "Replace"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var failures = 0
            for change in changes {
                self.history.record(change.url)
                guard let data = change.text.data(using: change.encoding, allowLossyConversion: false)
                        ?? change.text.data(using: .utf8), (try? data.write(to: change.url, options: .atomic)) != nil else {
                    failures += 1
                    continue
                }
            }
            self.syncWithDisk()
            self.sidebar.searchPane.refreshResults()
            let replaced = L("\(total) \(total == 1 ? "reemplazo" : "reemplazos") hechos", "\(total) \(total == 1 ? "replacement" : "replacements") made")
            if failures > 0 {
                self.setStatus(L("\(failures) archivos no se pudieron escribir", "\(failures) files couldn't be written"), .systemRed)
            } else {
                self.setStatus(replaced, .secondaryLabelColor)
            }
        }
    }
}
