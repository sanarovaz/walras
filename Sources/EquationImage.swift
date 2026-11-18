import AppKit
import PDFKit

/// Turns a piece of selected LaTeX into a cropped, high-resolution PNG.
enum EquationImage {
    enum Failure: Error {
        case noEngine
        case latex(String)
        case empty
    }

    private static let scale: CGFloat = 5
    private static let padding = 56
    private static let numberedEnvironment = try! NSRegularExpression(
        pattern: "\\\\(begin|end)\\{(equation|align|gather|multline|flalign|alignat)\\}")
    private static let label = try! NSRegularExpression(pattern: "\\\\label\\{[^{}]*\\}")
    private static let blankLines = try! NSRegularExpression(pattern: "\\n\\s*\\n")
    private static let beamerClass = try! NSRegularExpression(pattern: "\\\\documentclass(\\[[^\\]]*\\])?\\{beamer\\}")

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length),
                                         withTemplate: template)
    }

    /// A selection without delimiters is math, unless it is plainly running text.
    private static func needsMathMode(_ text: String) -> Bool {
        if ["\\begin{", "$", "\\[", "\\("].contains(where: { text.contains($0) }) { return false }
        let textCommands = ["\\text", "\\emph", "\\section", "\\subsection", "\\paragraph", "\\item", "\\cite", "\\footnote"]
        if textCommands.contains(where: { text.hasPrefix($0) }) { return false }
        let looksLikeMath = text.contains { "\\^_=+<>".contains($0) }
        return looksLikeMath || !text.contains(where: { $0.isWhitespace })
    }

    /// The numbers and labels are dropped so that the crop hugs the equation itself.
    private static func body(from selection: String) -> String {
        var text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        text = replacing(label, in: text, with: "")
        text = replacing(numberedEnvironment, in: text, with: "\\\\$1{$2*}")
        guard needsMathMode(text) else { return text }
        text = replacing(blankLines, in: text, with: "\n")
        if text.contains("&") { return "\\[\\begin{aligned}\n\(text)\n\\end{aligned}\\]" }
        if text.contains("\\\\") { return "\\[\\begin{gathered}\n\(text)\n\\end{gathered}\\]" }
        return "\\[\n\(text)\n\\]"
    }

    private static func document(preamble: String, selection: String) -> String {
        var content = body(from: selection)
        var extras = "\\usepackage{amsmath}\n"
        let range = NSRange(location: 0, length: (preamble as NSString).length)
        if beamerClass.firstMatch(in: preamble, options: [], range: range) != nil {
            extras += "\\setbeamertemplate{navigation symbols}{}\n"
            // On beamer, whatever is outside a frame never reaches the page.
            if !content.contains("\\begin{frame}") { content = "\\begin{frame}[plain]\n\(content)\n\\end{frame}" }
        }
        return "\(preamble)\n\(extras)\\begin{document}\n\\pagestyle{empty}\n\\thispagestyle{empty}\n\(content)\n\\end{document}\n"
    }

    /// Runs off the main thread. Compiles from the main file's folder, so that files the
    /// preamble inputs are found, with every generated file in a temporary folder.
    static func compile(selection: String, preamble: String, encoding: String.Encoding, main: URL,
                        engine: Engine) -> Result<(pdf: Data, pages: Int), Failure> {
        guard let tool = Compiler.findTool(engine.rawValue) else { return .failure(.noEngine) }
        let folder = Compiler.rootDirectory.appendingPathComponent("image-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("equation.tex")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = document(preamble: preamble, selection: selection).data(using: encoding, allowLossyConversion: true) else {
                return .failure(.empty)
            }
            try data.write(to: source)
        } catch {
            return .failure(.latex(error.localizedDescription))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-no-shell-escape",
                             "-output-directory=\(folder.path)", source.path]
        let workingDirectory = main.deletingLastPathComponent()
        process.currentDirectoryURL = workingDirectory
        process.environment = Compiler().makeEnvironment(workingDirectory: workingDirectory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.latex(error.localizedDescription))
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()

        let pdfURL = folder.appendingPathComponent("equation.pdf")
        guard process.terminationStatus == 0, let pdf = try? Data(contentsOf: pdfURL),
              let pages = PDFDocument(data: pdf)?.pageCount, pages > 0 else {
            let log = (try? Data(contentsOf: folder.appendingPathComponent("equation.log"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let issue = LogParser.parse(log: log).issues.first
            let details = [issue?.message, issue?.context].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return .failure(.latex(details.isEmpty ? L("LaTeX no generó el PDF.", "LaTeX didn't produce a PDF.") : details))
        }
        return .success((pdf: pdf, pages: pages))
    }

    /// Black on white, or the same pixels inverted for the dark version.
    static func render(pdf: Data, dark: Bool) -> NSBitmapImageRep? {
        guard let page = PDFDocument(data: pdf)?.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let drawScale = min(scale, 8000 / max(box.width, box.height))
        let width = Int(box.width * drawScale)
        let height = Int(box.height * drawScale)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let full = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: space, bitmapInfo: info), let pixels = full.data else { return nil }
        full.setFillColor(.white)
        full.fill(CGRect(x: 0, y: 0, width: width, height: height))
        full.scaleBy(x: drawScale, y: drawScale)
        page.draw(with: .mediaBox, to: full)

        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            let row = bytes + y * width * 4
            for x in 0..<width {
                let pixel = row + x * 4
                if pixel[0] < 245 || pixel[1] < 245 || pixel[2] < 245 {
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
        }
        guard right >= left, bottom >= top,
              let image = full.makeImage()?.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else {
            return nil
        }

        let finalWidth = image.width + 2 * padding
        let finalHeight = image.height + 2 * padding
        guard let canvas = CGContext(data: nil, width: finalWidth, height: finalHeight, bitsPerComponent: 8, bytesPerRow: finalWidth * 4,
                                     space: space, bitmapInfo: info), let canvasPixels = canvas.data else { return nil }
        canvas.setFillColor(.white)
        canvas.fill(CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight))
        canvas.draw(image, in: CGRect(x: padding, y: padding, width: image.width, height: image.height))
        if dark {
            let result = canvasPixels.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: finalWidth * finalHeight * 4, by: 4) {
                result[offset] = 255 - result[offset]
                result[offset + 1] = 255 - result[offset + 1]
                result[offset + 2] = 255 - result[offset + 2]
            }
        }
        guard let finished = canvas.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: finished)
        // Keeps its natural size when pasted into a document; the pixels stay for the screen.
        representation.size = NSSize(width: CGFloat(finalWidth) / drawScale, height: CGFloat(finalHeight) / drawScale)
        return representation
    }
}

extension ProjectWindowController {
    @objc func copySelectionAsImage(_ sender: Any?) { exportSelectionImage(dark: false) }
    @objc func copySelectionAsDarkImage(_ sender: Any?) { exportSelectionImage(dark: true) }

    private func exportSelectionImage(dark: Bool) {
        guard !isExportingImage else { return }
        let selection = editor.caretSnapshot().selection
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus(L("Seleccioná el LaTeX que querés copiar como imagen", "Select the LaTeX you want to copy as an image"), .secondaryLabelColor)
            return
        }
        guard let main = compileTarget() else {
            setStatus(L("Elegí un archivo principal para copiar como imagen", "Choose a main file to copy as an image"), .secondaryLabelColor)
            return
        }
        saveAll(interactive: false)
        guard let data = try? Data(contentsOf: main) else { return }
        let encoding: String.Encoding = String(data: data, encoding: .utf8) != nil ? .utf8 : .windowsCP1252
        guard let text = String(data: data, encoding: encoding),
              let start = text.range(of: "\\begin{document}") else {
            showImageError(L("No encontré \\begin{document} en el archivo principal.", "Couldn't find \\begin{document} in the main file."))
            return
        }
        let preamble = String(text[..<start.lowerBound])
        let currentEngine = engine
        isExportingImage = true
        setStatus(L("Generando la imagen…", "Generating the image…"), .secondaryLabelColor)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = EquationImage.compile(selection: selection, preamble: preamble, encoding: encoding,
                                               main: main, engine: currentEngine)
            var picture: NSBitmapImageRep?
            if case .success(let output) = result { picture = EquationImage.render(pdf: output.pdf, dark: dark) }
            let finished = picture
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExportingImage = false
                switch result {
                case .failure(.noEngine):
                    self.showImageError(L("No encontré \(currentEngine.title) en esta Mac.", "Couldn't find \(currentEngine.title) on this Mac."))
                case .failure(.latex(let message)):
                    self.showImageError(message)
                case .failure(.empty):
                    self.showImageError(L("La selección no generó nada para mostrar.", "The selection produced nothing to show."))
                case .success(let output):
                    self.finishImageExport(finished, pages: output.pages)
                }
            }
        }
    }

    private func finishImageExport(_ picture: NSBitmapImageRep?, pages: Int) {
        guard let picture, let png = picture.representation(using: .png, properties: [:]) else {
            showImageError(L("La selección no generó nada para mostrar.", "The selection produced nothing to show."))
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = picture.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        if pages > 1 {
            setStatus(L("Imagen copiada, solo con la primera de \(pages) páginas", "Image copied, with only the first of \(pages) pages"), .systemOrange)
        } else {
            setStatus(L("Imagen copiada · \(picture.pixelsWide) × \(picture.pixelsHigh) px", "Image copied · \(picture.pixelsWide) × \(picture.pixelsHigh) px"), .secondaryLabelColor)
        }
    }

    private func showImageError(_ message: String) {
        guard let window else { return }
        setStatus("", .secondaryLabelColor)
        let alert = NSAlert()
        alert.messageText = L("No se pudo generar la imagen", "Couldn't generate the image")
        alert.informativeText = String(message.prefix(1200))
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
