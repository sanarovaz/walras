import AppKit

struct BibEntry {
    let key: String
    let author: String
    let title: String
    let year: String
    let searchText: String
    var fields: [String: String] = [:]

    var summary: String {
        let authorYear = year.isEmpty ? author : "\(author) (\(year))"
        if authorYear.isEmpty { return title }
        return title.isEmpty ? authorYear : "\(authorYear) · \(title)"
    }
}

enum BibParser {
    private static let at = UInt8(ascii: "@")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")
    private static let comma = UInt8(ascii: ",")
    private static let equals = UInt8(ascii: "=")
    private static let quote = UInt8(ascii: "\"")
    private static let hash = UInt8(ascii: "#")
    private static let backslash = UInt8(ascii: "\\")

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func isFieldNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95 || byte == 58 || byte == 46
    }

    static func parse(_ text: String) -> [BibEntry] {
        let bytes = Array(text.utf8)
        let count = bytes.count
        var index = 0
        var entries: [BibEntry] = []

        func skipSpace() {
            while index < count, isSpace(bytes[index]) { index += 1 }
        }

        func slice(_ start: Int, _ end: Int) -> String {
            String(decoding: bytes[start..<end], as: UTF8.self)
        }

        /// With `index` on an opening brace, returns the inner text and moves past the closer.
        func readBraced() -> String {
            var depth = 0
            let start = index + 1
            while index < count {
                let byte = bytes[index]
                if byte == backslash {
                    index += 2
                    continue
                }
                if byte == openBrace { depth += 1 }
                if byte == closeBrace {
                    depth -= 1
                    if depth == 0 {
                        let value = slice(start, index)
                        index += 1
                        return value
                    }
                }
                index += 1
            }
            index = count
            return start <= count ? slice(start, count) : ""
        }

        func readQuoted() -> String {
            index += 1
            let start = index
            var depth = 0
            while index < count {
                let byte = bytes[index]
                if byte == backslash {
                    index += 2
                    continue
                }
                if byte == openBrace { depth += 1 }
                if byte == closeBrace { depth -= 1 }
                if byte == quote, depth <= 0 {
                    let value = slice(start, index)
                    index += 1
                    return value
                }
                index += 1
            }
            index = count
            return start <= count ? slice(start, count) : ""
        }

        func readValue(closer: UInt8) -> String {
            var value = ""
            while index < count {
                skipSpace()
                guard index < count else { break }
                let byte = bytes[index]
                if byte == openBrace {
                    value += readBraced()
                } else if byte == quote {
                    value += readQuoted()
                } else {
                    let start = index
                    while index < count, !isSpace(bytes[index]), bytes[index] != comma,
                          bytes[index] != closer, bytes[index] != hash {
                        index += 1
                    }
                    value += slice(start, index)
                }
                skipSpace()
                if index < count, bytes[index] == hash {
                    index += 1
                    continue
                }
                break
            }
            return value
        }

        while index < count {
            guard bytes[index] == at else {
                index += 1
                continue
            }
            index += 1
            let typeStart = index
            while index < count, isLetter(bytes[index]) { index += 1 }
            let type = slice(typeStart, index).lowercased()
            skipSpace()
            guard index < count, bytes[index] == openBrace || bytes[index] == openParen else { continue }
            let closer = bytes[index] == openBrace ? closeBrace : closeParen

            if type.isEmpty || type == "comment" || type == "string" || type == "preamble" {
                if bytes[index] == openBrace { _ = readBraced() }
                continue
            }

            index += 1
            skipSpace()
            let keyStart = index
            while index < count, bytes[index] != comma, bytes[index] != closer, !isSpace(bytes[index]) {
                index += 1
            }
            let key = slice(keyStart, index)

            var fields: [String: String] = [:]
            while index < count {
                while index < count, isSpace(bytes[index]) || bytes[index] == comma { index += 1 }
                guard index < count else { break }
                if bytes[index] == closer {
                    index += 1
                    break
                }
                let nameStart = index
                while index < count, isFieldNameByte(bytes[index]) { index += 1 }
                let name = slice(nameStart, index).lowercased()
                skipSpace()
                guard index < count, bytes[index] == equals, !name.isEmpty else {
                    // Malformed entry: resume at the next one instead of getting stuck.
                    if index == nameStart { index += 1 }
                    if index < count, bytes[index] == at { break }
                    continue
                }
                index += 1
                fields[name] = readValue(closer: closer)
            }

            guard !key.isEmpty else { continue }
            entries.append(makeEntry(key: key, fields: fields))
        }
        return entries
    }

    private static func makeEntry(key: String, fields: [String: String]) -> BibEntry {
        let author = shortAuthors(clean(fields["author"] ?? fields["editor"] ?? ""))
        let title = clean(fields["title"] ?? "")
        var year = clean(fields["year"] ?? "")
        if year.isEmpty, let date = fields["date"] { year = String(clean(date).prefix(4)) }
        let everything = [key, clean(fields["author"] ?? fields["editor"] ?? ""), title, year].joined(separator: " ")
        return BibEntry(key: key, author: author, title: title, year: year, searchText: fold(everything), fields: fields.mapValues(clean))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func clean(_ raw: String) -> String {
        var text = raw
        for accent in ["\\'", "\\\"", "\\`", "\\~", "\\^", "\\c ", "\\v ", "\\H "] {
            text = text.replacingOccurrences(of: accent, with: "")
        }
        text = text.replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "--", with: "–")
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func shortAuthors(_ names: String) -> String {
        guard !names.isEmpty else { return "" }
        let people = names.components(separatedBy: " and ")
        let surnames: [String] = people.map { person in
            if let comma = person.firstIndex(of: ",") { return String(person[..<comma]) }
            return person.split(separator: " ").last.map(String.init) ?? person
        }
        if surnames.count == 1 { return surnames[0] }
        if surnames.count == 2 { return L("\(surnames[0]) y \(surnames[1])", "\(surnames[0]) and \(surnames[1])") }
        return "\(surnames[0]) et al."
    }
}

/// Every reference in the project's .bib files.
final class CitationIndex {
    private(set) var entries: [BibEntry] = []
    private var generation = 0

    func reload(root: URL) {
        generation += 1
        let current = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [BibEntry] = []
            var seen = Set<String>()
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "bib", let data = try? Data(contentsOf: url) else { continue }
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                for entry in BibParser.parse(text) where seen.insert(entry.key).inserted {
                    found.append(entry)
                }
            }
            found.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.entries = found
            }
        }
    }

    func matches(for query: String, limit: Int = 40) -> [BibEntry] {
        let tokens = BibParser.fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.isEmpty { return Array(entries.prefix(limit)) }
        let hits = entries.filter { entry in tokens.allSatisfy { entry.searchText.contains($0) } }
        let foldedQuery = tokens.joined(separator: " ")
        let prefixed = hits.filter { BibParser.fold($0.key).hasPrefix(foldedQuery) }
        let others = hits.filter { !BibParser.fold($0.key).hasPrefix(foldedQuery) }
        return Array((prefixed + others).prefix(limit))
    }
}
