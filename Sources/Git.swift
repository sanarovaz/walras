import AppKit

/// Thin wrapper around the git already installed on the Mac. It reuses the
/// credentials git is configured with, and stores none of its own.
struct GitRunner {
    let directory: URL

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 180) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Compiler.findTool("git") ?? "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (Compiler.searchDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        // A GUI app has no terminal to answer in: fail with a message instead of hanging.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (false, L("No se pudo ejecutar git: \(error.localizedDescription)", "Couldn't run git: \(error.localizedDescription)"))
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, output)
    }
}

enum GitDialogs {
    /// Asks for the address of an empty repository. Returns nil if cancelled.
    static func askForRemote(window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Conectar este proyecto con GitHub", "Connect this project to GitHub")
        alert.informativeText = L("Creá un repositorio vacío en github.com y pegá acá su dirección, por ejemplo https://github.com/usuario/repo.git", "Create an empty repository on github.com and paste its address here, for example https://github.com/user/repo.git")
        alert.addButton(withTitle: L("Conectar", "Connect"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://github.com/usuario/repo.git"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Shows what will be uploaded and asks for a description.
    /// Returns nil if cancelled. `changes` is empty when only pending commits remain.
    static func askForCommit(changes: [String], remote: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Subir a GitHub", "Push to GitHub")
        if changes.isEmpty {
            alert.informativeText = L("No hay archivos nuevos: se suben los cambios que quedaron pendientes a \(remote).", "No new files: pending changes will be pushed to \(remote).")
        } else {
            let count = changes.count
            alert.informativeText = L("\(count) \(count == 1 ? "archivo" : "archivos") con cambios irán a \(remote).", "\(count) changed \(count == 1 ? "file" : "files") will go to \(remote).")
        }
        alert.addButton(withTitle: L("Subir", "Push"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))

        let formatter = DateFormatter()
        formatter.dateFormat = "d/M/yyyy HH:mm"
        let field = NSTextField(frame: NSRect(x: 0, y: 134, width: 400, height: 24))
        field.stringValue = L("Cambios del \(formatter.string(from: Date()))", "Changes from \(formatter.string(from: Date()))")

        let list = NSTextView.scrollableTextView()
        list.frame = NSRect(x: 0, y: 0, width: 400, height: 124)
        list.borderType = .bezelBorder
        if let text = list.documentView as? NSTextView {
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = changes.joined(separator: "\n")
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: changes.isEmpty ? 24 : 158))
        if changes.isEmpty {
            field.frame.origin.y = 0
        } else {
            accessory.addSubview(list)
        }
        accessory.addSubview(field)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L("Cambios", "Changes") : message
    }
}

extension ProjectWindowController {
    private static let defaultGitignore = """
    # Generados por LaTeX
    *.aux
    *.log
    *.out
    *.toc
    *.lof
    *.lot
    *.fls
    *.fdb_latexmk
    *.synctex.gz
    *.bbl
    *.blg
    *.bcf
    *.run.xml
    *.nav
    *.snm
    *.vrb
    *.xdv
    .DS_Store

    """

    @objc func pushToGitHub(_ sender: Any?) {
        guard !gitBusy else { return }
        saveAll(interactive: true)
        gitBusy = true
        beginGitActivity(L("Revisando cambios…", "Checking changes…"))
        let directory = root
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message = self?.performPush(GitRunner(directory: directory))
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitBusy = false
                self.endGitActivity(message ?? "")
                self.syncWithDisk()
            }
        }
    }

    private func onMain<T>(_ work: () -> T) -> T {
        DispatchQueue.main.sync(execute: work)
    }

    private func showGitFailure(_ title: String, _ detail: String) {
        onMain {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = String(detail.suffix(1500))
            alert.runModal()
        }
    }

    /// Runs on a background thread. Returns the text for the status bar.
    private func performPush(_ git: GitRunner) -> String {
        let isRepository = git.run(["rev-parse", "--is-inside-work-tree"]).ok
        var remote = git.run(["remote"]).output.split(separator: "\n").first.map(String.init)

        if !isRepository || remote == nil {
            guard let url = onMain({ GitDialogs.askForRemote(window: window) }) else { return "" }
            if !isRepository {
                let created = git.run(["init", "-b", "main"])
                guard created.ok else {
                    showGitFailure(L("No se pudo preparar la carpeta.", "Couldn't prepare the folder."), created.output)
                    return L("No se subió", "Not pushed")
                }
                let ignore = git.directory.appendingPathComponent(".gitignore")
                if !FileManager.default.fileExists(atPath: ignore.path) {
                    try? Data(Self.defaultGitignore.utf8).write(to: ignore)
                }
            }
            let added = git.run(["remote", "add", "origin", url])
            guard added.ok else {
                showGitFailure(L("No se pudo conectar el repositorio.", "Couldn't connect the repository."), added.output)
                return L("No se subió", "Not pushed")
            }
            remote = "origin"
        }
        guard let remote else { return "" }

        let changes = git.run(["status", "--short", "--", "."]).output
            .split(separator: "\n").map(String.init)
        let hasCommits = git.run(["rev-parse", "--verify", "HEAD"]).ok
        let upstreamCount = git.run(["rev-list", "--count", "@{u}..HEAD"])
        let pendingCommits = hasCommits && (!upstreamCount.ok || upstreamCount.output != "0")

        if changes.isEmpty && !pendingCommits { return L("Nada nuevo para subir", "Nothing new to push") }

        let address = git.run(["remote", "get-url", remote]).output
        guard let message = onMain({ GitDialogs.askForCommit(changes: changes, remote: address) }) else { return "" }

        DispatchQueue.main.async { self.beginGitActivity(L("Subiendo a GitHub…", "Pushing to GitHub…")) }

        if !changes.isEmpty {
            let staged = git.run(["add", "-A", "--", "."])
            guard staged.ok else {
                showGitFailure(L("No se pudieron preparar los archivos.", "Couldn't prepare the files."), staged.output)
                return L("No se subió", "Not pushed")
            }
            let committed = git.run(["commit", "-m", message])
            guard committed.ok else {
                showGitFailure(L("No se pudieron registrar los cambios.", "Couldn't commit the changes."), committed.output)
                return L("No se subió", "Not pushed")
            }
        }

        var pushed = git.run(["push", "-u", remote, "HEAD"])
        let wasRejected = pushed.output.contains("[rejected]") || pushed.output.contains("fetch first")
            || pushed.output.contains("non-fast-forward")
        if !pushed.ok && wasRejected {
            let retry: Bool = onMain {
                let alert = NSAlert()
                alert.messageText = L("GitHub tiene cambios que no están en esta Mac.", "GitHub has changes that aren't on this Mac.")
                alert.informativeText = L("Podés traerlos, combinarlos con los tuyos y volver a subir.", "You can fetch them, combine them with yours and push again.")
                alert.addButton(withTitle: L("Traer y subir", "Fetch and Push"))
                alert.addButton(withTitle: L("Cancelar", "Cancel"))
                return alert.runModal() == .alertFirstButtonReturn
            }
            guard retry else { return L("Sin subir: GitHub tiene otros cambios", "Not pushed: GitHub has other changes") }
            let branch = git.run(["branch", "--show-current"]).output
            let pulled = git.run(["pull", "--rebase", "--autostash", remote, branch.isEmpty ? "HEAD" : branch])
            guard pulled.ok else {
                git.run(["rebase", "--abort"])
                showGitFailure(L("Los cambios se pisan entre sí y no se pudieron combinar solos. Tus archivos quedaron como estaban.", "The changes conflict and couldn't be combined automatically. Your files were left as they were."), pulled.output)
                return L("No se subió", "Not pushed")
            }
            pushed = git.run(["push", "-u", remote, "HEAD"])
        }
        guard pushed.ok else {
            showGitFailure(L("No se pudo subir a GitHub. Los cambios quedaron guardados y se subirán en el próximo intento.", "Couldn't push to GitHub. The changes are saved and will be pushed on the next try."), pushed.output)
            return L("No se subió", "Not pushed")
        }
        return L("Subido a GitHub", "Pushed to GitHub")
    }
}
