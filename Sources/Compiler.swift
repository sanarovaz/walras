import Foundation

enum Engine: String, CaseIterable {
    case pdflatex, xelatex, lualatex

    var title: String {
        switch self {
        case .pdflatex: return "pdfLaTeX"
        case .xelatex: return "XeLaTeX"
        case .lualatex: return "LuaLaTeX"
        }
    }

    var latexmkFlag: String {
        switch self {
        case .pdflatex: return "-pdf"
        case .xelatex: return "-pdfxe"
        case .lualatex: return "-pdflua"
        }
    }
}

struct CompileIssue {
    let file: String?
    let line: Int?
    let message: String
    /// The lines that follow the error in LaTeX's log, which usually show the offending code.
    let context: String
}

struct CompileResult {
    let pdfData: Data?
    let output: String
    var log: String = ""
    let issues: [CompileIssue]
    let warningCount: Int
    let duration: TimeInterval
    let workingDirectory: URL
    let cancelled: Bool
    let setupError: String?
}

/// Runs LaTeX with every generated file (PDF included) confined to a temporary
/// directory. Nothing is written next to the user's sources. The directory is
/// removed when the project window closes and any leftovers on the next launch.
final class Compiler {
    static var rootDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Walras", isDirectory: true)
    }

    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private let baseDirectory: URL
    /// One per document: two documents named main.tex must not share their PDF and aux files.
    private(set) var buildDirectory: URL

    private let lock = NSLock()
    private var currentProcess: Process?
    private var running = false
    private var cancelRequested = false

    init() {
        baseDirectory = Compiler.rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        buildDirectory = baseDirectory
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func dispose() {
        cancel()
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    func clearBuildDirectory() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let process = currentProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        // latexmk spawns the engine as a child, so stop the children too.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        process.terminate()
    }

    /// Asks SyncTeX which source line produced a point of the last compiled PDF.
    /// `page` starts at 1; x and y are in points measured from the page's top left.
    /// The file path comes back as written by LaTeX, which may be relative.
    func sourceLocation(page: Int, x: Double, y: Double, stem: String,
                        completion: @escaping ((file: String, line: Int)?) -> Void) {
        guard let synctex = Compiler.findTool("synctex") else {
            completion(nil)
            return
        }
        let pdf = buildDirectory.appendingPathComponent(stem + ".pdf").path
        let query = "\(page):\(x):\(y):\(pdf)"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: synctex)
            process.arguments = ["edit", "-o", query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var found: (file: String, line: Int)?
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var file: String?
                for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
                    if line.hasPrefix("Input:") {
                        file = String(line.dropFirst(6))
                    } else if line.hasPrefix("Line:"), let current = file, let number = Int(line.dropFirst(5)), number > 0 {
                        found = (current, number)
                        break
                    }
                }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// Asks SyncTeX where a source line ended up in the last compiled PDF. The box is in
    /// points from the page's top left, with `bottom` at its lower edge.
    func pdfLocation(file: URL, line: Int, stem: String,
                     completion: @escaping ((page: Int, left: Double, bottom: Double, width: Double, height: Double)?) -> Void) {
        guard let synctex = Compiler.findTool("synctex") else {
            completion(nil)
            return
        }
        let pdf = buildDirectory.appendingPathComponent(stem + ".pdf").path
        let query = "\(line):0:\(file.standardizedFileURL.path)"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: synctex)
            process.arguments = ["view", "-i", query, "-o", pdf]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var found: (page: Int, left: Double, bottom: Double, width: Double, height: Double)?
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var values: [String: Double] = [:]
                // One record per box; some have no height, so the first with one is the line itself.
                for text in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
                    let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    if parts[0] == "Output" { values = [:] }
                    values[parts[0]] = Double(parts[1])
                    guard parts[0] == "H", let page = values["Page"], let left = values["h"], let bottom = values["v"],
                          let width = values["W"], let height = values["H"] else { continue }
                    if found == nil || (found?.height == 0 && height > 0) {
                        found = (Int(page), left, bottom, width, height)
                    }
                }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    func compile(main: URL, engine: Engine, completion: @escaping (CompileResult) -> Void) {
        lock.lock()
        running = true
        cancelRequested = false
        lock.unlock()
        let key = String(UInt(bitPattern: main.standardizedFileURL.path.hashValue))
        buildDirectory = baseDirectory.appendingPathComponent(key, isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = perform(main: main, engine: engine)
            lock.lock()
            running = false
            currentProcess = nil
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Implementation

    private func perform(main: URL, engine: Engine) -> CompileResult {
        let start = Date()
        let workingDirectory = main.deletingLastPathComponent()
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
            mirrorSubdirectories(of: workingDirectory)
        } catch {
            return CompileResult(pdfData: nil, output: "", issues: [], warningCount: 0, duration: 0,
                                 workingDirectory: workingDirectory, cancelled: false,
                                 setupError: L("No se pudo crear la carpeta temporal: \(error.localizedDescription)", "Couldn't create the temporary folder: \(error.localizedDescription)"))
        }

        let environment = makeEnvironment(workingDirectory: workingDirectory)
        var output = ""
        let stem = main.deletingPathExtension().lastPathComponent

        if let latexmk = Compiler.findTool("latexmk") {
            let arguments = [
                engine.latexmkFlag, "-f",
                "-interaction=nonstopmode", "-file-line-error", "-no-shell-escape", "-synctex=1",
                "-outdir=\(buildDirectory.path)",
                main.lastPathComponent,
            ]
            _ = run(latexmk, arguments, in: workingDirectory, environment: environment, output: &output)
        } else if let engineTool = Compiler.findTool(engine.rawValue) {
            runWithoutLatexmk(engineTool: engineTool, main: main, stem: stem,
                              workingDirectory: workingDirectory, environment: environment, output: &output)
        } else {
            return CompileResult(pdfData: nil, output: "", issues: [], warningCount: 0, duration: 0,
                                 workingDirectory: workingDirectory, cancelled: false,
                                 setupError: L("No encontré LaTeX en esta Mac. Instalá MacTeX o TinyTeX y volvé a intentar.", "LaTeX wasn't found on this Mac. Install MacTeX or TinyTeX and try again."))
        }

        let log = readLog(stem: stem)
        let parsed = LogParser.parse(log: log.isEmpty ? output : log)
        let pdfURL = buildDirectory.appendingPathComponent(stem + ".pdf")
        let pdfData = try? Data(contentsOf: pdfURL)

        lock.lock()
        let wasCancelled = cancelRequested
        lock.unlock()

        return CompileResult(pdfData: pdfData, output: output, log: log, issues: parsed.issues,
                             warningCount: parsed.warnings, duration: Date().timeIntervalSince(start),
                             workingDirectory: workingDirectory, cancelled: wasCancelled, setupError: nil)
    }

    /// Used only on minimal TeX installs that do not include latexmk.
    private func runWithoutLatexmk(engineTool: String, main: URL, stem: String, workingDirectory: URL,
                                   environment: [String: String], output: inout String) {
        let arguments = [
            "-interaction=nonstopmode", "-file-line-error", "-no-shell-escape", "-synctex=1",
            "-output-directory=\(buildDirectory.path)", main.lastPathComponent,
        ]
        _ = run(engineTool, arguments, in: workingDirectory, environment: environment, output: &output)
        if isCancelled { return }

        let fm = FileManager.default
        let bcf = buildDirectory.appendingPathComponent(stem + ".bcf")
        let aux = buildDirectory.appendingPathComponent(stem + ".aux")
        if fm.fileExists(atPath: bcf.path), let biber = Compiler.findTool("biber") {
            _ = run(biber, ["--input-directory=\(workingDirectory.path)",
                            "--output-directory=\(buildDirectory.path)", bcf.path],
                    in: buildDirectory, environment: environment, output: &output)
        } else if let auxText = try? String(contentsOf: aux, encoding: .isoLatin1),
                  auxText.contains("\\bibdata"), let bibtex = Compiler.findTool("bibtex") {
            _ = run(bibtex, [stem], in: buildDirectory, environment: environment, output: &output)
        }

        for _ in 0..<3 {
            if isCancelled { return }
            _ = run(engineTool, arguments, in: workingDirectory, environment: environment, output: &output)
            let log = readLog(stem: stem)
            if !log.contains("Rerun to get") && !log.contains("Label(s) may have changed") { break }
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    private func readLog(stem: String) -> String {
        let url = buildDirectory.appendingPathComponent(stem + ".log")
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// \include{chapters/x} requires chapters/ to exist in the output directory.
    private func mirrorSubdirectories(of directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            try? fm.createDirectory(at: buildDirectory.appendingPathComponent(relative, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL,
                     environment: [String: String], output: inout String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        lock.lock()
        currentProcess = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            output += L("No se pudo ejecutar \(executable): \(error.localizedDescription)\n", "Couldn't run \(executable): \(error.localizedDescription)\n")
            return -1
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        output += String(decoding: data, as: UTF8.self)
        return process.terminationStatus
    }

    func makeEnvironment(workingDirectory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Apps launched from Finder do not inherit the shell's PATH.
        environment["PATH"] = (Compiler.searchDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["max_print_line"] = "1000"
        environment["error_line"] = "254"
        environment["half_error_line"] = "238"
        environment["BIBINPUTS"] = workingDirectory.path + ":"
        environment["BSTINPUTS"] = workingDirectory.path + ":"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }

    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Library/TeX/texbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/Library/TinyTeX/bin/universal-darwin",
            "\(home)/bin",
        ]
    }

    static func findTool(_ name: String) -> String? {
        for directory in searchDirectories {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

enum LogParser {
    private static let located = try! NSRegularExpression(pattern: "^(.+?\\.[A-Za-z0-9]+):([0-9]+): (.+)$",
                                                          options: [.anchorsMatchLines])
    private static let unlocated = try! NSRegularExpression(pattern: "^! (.+)$", options: [.anchorsMatchLines])
    private static let warning = try! NSRegularExpression(pattern: "^(?:LaTeX|Package|Class) .*Warning[: ]",
                                                          options: [.anchorsMatchLines])

    static func parse(log: String) -> (issues: [CompileIssue], warnings: Int) {
        let text = log as NSString
        let full = NSRange(location: 0, length: text.length)
        var issues: [CompileIssue] = []
        var seen = Set<String>()

        for match in located.matches(in: log, options: [], range: full) {
            let file = text.substring(with: match.range(at: 1))
            let line = Int(text.substring(with: match.range(at: 2)))
            let message = text.substring(with: match.range(at: 3))
            let key = "\(file):\(line ?? 0):\(message)"
            if seen.insert(key).inserted {
                issues.append(CompileIssue(file: file, line: line, message: message,
                                           context: context(in: text, after: NSMaxRange(match.range))))
            }
        }
        if issues.isEmpty {
            for match in unlocated.matches(in: log, options: [], range: full) {
                let message = text.substring(with: match.range(at: 1))
                if seen.insert(message).inserted {
                    issues.append(CompileIssue(file: nil, line: nil, message: message,
                                               context: context(in: text, after: NSMaxRange(match.range))))
                }
            }
        }
        return (issues, warning.numberOfMatches(in: log, options: [], range: full))
    }

    /// Up to eight lines after the error, stopping at the blank line that ends the block.
    private static func context(in text: NSString, after location: Int) -> String {
        let length = min(1200, text.length - location)
        guard length > 0 else { return "" }
        var kept: [String] = []
        let lines = text.substring(with: NSRange(location: location, length: length)).components(separatedBy: "\n")
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || kept.count == 8 { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}
