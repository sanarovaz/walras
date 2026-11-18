import AppKit

/// Turns the contents of \title{} into a file name.
enum DocumentTitle {
    private static let comment = try! NSRegularExpression(pattern: "(?m)(?<!\\\\)%.*$")
    private static let titleCommand = try! NSRegularExpression(pattern: "\\\\title\\s*(?:\\[[^\\]]*\\])?\\s*\\{")
    private static let accent = try! NSRegularExpression(pattern: "\\\\(['`^\"~])\\s*\\{?\\\\?([A-Za-z])\\}?")
    private static let lineBreak = try! NSRegularExpression(pattern: "\\\\\\\\\\*?(?:\\[[^\\]]*\\])?")
    private static let command = try! NSRegularExpression(pattern: "\\\\[a-zA-Z@]+\\*?(?:\\[[^\\]]*\\])?")
    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    private static let combining: [String: String] = ["'": "\u{301}", "`": "\u{300}", "^": "\u{302}", "\"": "\u{308}", "~": "\u{303}"]

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length),
                                         withTemplate: template)
    }

    /// The text up to the brace matching the one just before `start`.
    private static func braced(_ text: NSString, from start: Int) -> NSRange? {
        var depth = 1
        var index = start
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 92 { // backslash: whatever follows is escaped
                index += 2
                continue
            }
            if unit == 123 { depth += 1 }
            if unit == 125 {
                depth -= 1
                if depth == 0 { return NSRange(location: start, length: index - start) }
            }
            index += 1
        }
        return nil
    }

    private static func removingCommandWithArgument(_ name: String, from text: String) -> String {
        var result = text as NSString
        while true {
            let found = result.range(of: "\\\(name){")
            guard found.location != NSNotFound, let inside = braced(result, from: NSMaxRange(found)) else { return result as String }
            result = result.replacingCharacters(in: NSRange(location: found.location, length: NSMaxRange(inside) + 1 - found.location), with: "") as NSString
        }
    }

    static func fileName(fromLaTeX source: String) -> String? {
        let text = replacing(comment, in: source, with: "")
        let nsText = text as NSString
        guard let match = titleCommand.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
              let inside = braced(nsText, from: NSMaxRange(match.range)) else { return nil }
        var title = nsText.substring(with: inside)
        title = removingCommandWithArgument("thanks", from: title)
        title = removingCommandWithArgument("footnote", from: title)
        title = replacing(lineBreak, in: title, with: " ")

        let accented = NSMutableString(string: title)
        for found in accent.matches(in: title, options: [], range: NSRange(location: 0, length: accented.length)).reversed() {
            let mark = combining[accented.substring(with: found.range(at: 1))] ?? ""
            accented.replaceCharacters(in: found.range, with: accented.substring(with: found.range(at: 2)) + mark)
        }
        title = (accented as String).precomposedStringWithCanonicalMapping

        for (escaped, plain) in [("\\&", "&"), ("\\%", "%"), ("\\_", "_"), ("\\#", "#"), ("\\$", "$"), ("\\LaTeX", "LaTeX"), ("\\TeX", "TeX")] {
            title = title.replacingOccurrences(of: escaped, with: plain)
        }
        title = replacing(command, in: title, with: "")
        title = title.replacingOccurrences(of: "~", with: " ")
        let invalid = CharacterSet(charactersIn: "{}$/\\:*?\"<>|").union(.controlCharacters)
        title = String(String.UnicodeScalarView(title.unicodeScalars.filter { !invalid.contains($0) }))
        title = replacing(whitespace, in: title, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        while title.utf8.count > 240 { title.removeLast() }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return title.isEmpty ? nil : title
    }
}

/// While a project is open, saves the PDF next to each document that changed, every hour
/// and on the way out. It compiles on its own, without touching the visible PDF or log.
extension ProjectWindowController {
    private static let watchedExtensions: Set<String> = ["tex", "ltx", "bib"]

    func sourceSnapshot() -> [String: Date] {
        var dates: [String: Date] = [:]
        for url in ProjectFiles.allFiles(in: ProjectFiles.scan(root))
        where Self.watchedExtensions.contains(url.pathExtension.lowercased()) {
            if let date = TextBuffer.modificationDate(of: url) { dates[url.standardizedFileURL.path] = date }
        }
        return dates
    }

    func exportChangedDocuments() {
        guard !isExportingPDF else { return }
        saveAll(interactive: false)
        let current = sourceSnapshot()
        let changed = current.filter { pdfBaseline[$0.key] != $0.value }.keys
        pdfBaseline = current
        guard !changed.isEmpty else { return }
        var targets: [String: URL] = [:]
        for path in changed {
            if let target = document(containing: URL(fileURLWithPath: path)) {
                targets[target.standardizedFileURL.path] = target
            }
        }
        guard !targets.isEmpty else { return }
        pdfQueue = targets.keys.sorted().compactMap { targets[$0] }
        isExportingPDF = true
        exportNextDocument()
    }

    /// Calls `completion` once nothing is left to save, right away if there was nothing to do.
    func finishPDFExports(_ completion: @escaping () -> Void) {
        exportChangedDocuments()
        if isExportingPDF {
            pdfExportWaiters.append(completion)
        } else {
            completion()
        }
    }

    private func exportNextDocument() {
        guard !pdfQueue.isEmpty else {
            isExportingPDF = false
            guard !pdfExportWaiters.isEmpty else { return }
            // Someone is leaving: catch what changed during the run that just ended.
            exportChangedDocuments()
            if !isExportingPDF {
                let waiters = pdfExportWaiters
                pdfExportWaiters = []
                waiters.forEach { $0() }
            }
            return
        }
        let target = pdfQueue.removeFirst()
        pdfCompiler.compile(main: target, engine: engine) { [self] result in
            savePDF(result, of: target)
            exportNextDocument()
        }
    }

    private func pdfTitle(of document: URL) -> String {
        let source = buffers[document.standardizedFileURL.path]?.storage.string
            ?? (try? Data(contentsOf: document)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return DocumentTitle.fileName(fromLaTeX: source) ?? document.deletingPathExtension().lastPathComponent
    }

    /// The document's title, plus its file name when another document in the same folder
    /// has the same title, so that neither PDF overwrites the other.
    private func pdfName(for target: URL) -> String {
        let title = pdfTitle(of: target)
        let folder = target.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let sharesTitle = names.map { folder.appendingPathComponent($0) }.contains { other in
            other.standardizedFileURL.path != target.standardizedFileURL.path
                && isStandaloneDocument(other)
                && pdfTitle(of: other).caseInsensitiveCompare(title) == .orderedSame
        }
        guard sharesTitle else { return title }
        return "\(title) (\(target.deletingPathExtension().lastPathComponent))"
    }

    private func savePDF(_ result: CompileResult, of target: URL) {
        guard result.setupError == nil, !result.cancelled else { return }
        guard result.issues.isEmpty, let pdf = result.pdfData else {
            noteExport(L("No guardé el PDF de \(target.lastPathComponent): tiene errores", "Didn't save the PDF of \(target.lastPathComponent): it has errors"), .systemOrange)
            return
        }
        let name = pdfName(for: target)
        let destination = target.deletingLastPathComponent().appendingPathComponent(name + ".pdf")
        var owned = ((UserDefaults.standard.dictionary(forKey: defaultsKey)?["autosavedPDFs"] as? String) ?? "")
            .split(separator: "\n").map(String.init)
        let key = relativePath(destination)
        do {
            // A PDF this feature didn't write goes to the Trash rather than being lost.
            if FileManager.default.fileExists(atPath: destination.path), !owned.contains(key) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try pdf.write(to: destination, options: .atomic)
        } catch {
            noteExport(L("No se pudo guardar \(destination.lastPathComponent)", "Couldn't save \(destination.lastPathComponent)"), .systemOrange)
            return
        }
        if !owned.contains(key) {
            owned.append(key)
            storeSetting("autosavedPDFs", owned.joined(separator: "\n"))
        }
        noteExport(L("PDF guardado: \(destination.lastPathComponent)", "PDF saved: \(destination.lastPathComponent)"), .secondaryLabelColor)
    }
}
