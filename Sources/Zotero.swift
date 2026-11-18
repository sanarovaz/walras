import AppKit

/// Talks only to the Zotero app running on this Mac (its local API), never to zotero.org.
enum ZoteroClient {
    enum Failure: Error {
        case notInstalled, notRunning, disabled, other(String)

        var message: String {
            switch self {
            case .notInstalled:
                return L("No encontré Zotero en esta Mac. Instalalo desde zotero.org y volvé a intentar.", "Zotero wasn't found on this Mac. Install it from zotero.org and try again.")
            case .notRunning:
                return L("Zotero no está abierto. Abrilo y volvé a intentar.", "Zotero isn't open. Open it and try again.")
            case .disabled:
                return L("Zotero no permite la conexión todavía. En Zotero, andá a Ajustes > Avanzado y activá “Permitir que otras aplicaciones de este ordenador se comuniquen con Zotero”.", "Zotero isn't allowing the connection yet. In Zotero, go to Settings > Advanced and turn on “Allow other applications on this computer to communicate with Zotero”.")
            case .other(let detail):
                return L("Zotero devolvió un error: \(detail)", "Zotero returned an error: \(detail)")
            }
        }
    }

    struct Collection {
        let key: String
        let name: String
    }

    private static let base = "http://localhost:23119/api/users/0"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.zotero.zotero") != nil
    }

    private static func get(_ path: String, completion: @escaping (Result<Data, Failure>) -> Void) {
        guard let url = URL(string: base + path) else {
            completion(.failure(.other(L("dirección inválida", "invalid address"))))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Data, Failure>
            if error != nil {
                result = .failure(isInstalled ? .notRunning : .notInstalled)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 403 {
                result = .failure(.disabled)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(.other(L("código \(http.statusCode)", "code \(http.statusCode)")))
            } else {
                result = .success(data ?? Data())
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func collections(completion: @escaping (Result<[Collection], Failure>) -> Void) {
        get("/collections") { result in
            completion(result.map { data in
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                let list = json.compactMap { item -> Collection? in
                    guard let key = item["key"] as? String,
                          let details = item["data"] as? [String: Any],
                          let name = details["name"] as? String else { return nil }
                    return Collection(key: key, name: name)
                }
                return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            })
        }
    }

    /// `collection` empty means the whole library.
    static func bibtex(collection: String, completion: @escaping (Result<String, Failure>) -> Void) {
        let scope = collection.isEmpty ? "" : "/collections/\(collection)"
        get("\(scope)/items/top?format=bibtex") { result in
            completion(result.map { String(decoding: $0, as: UTF8.self) })
        }
    }
}

extension ProjectWindowController {
    private static let zoteroHeader = "% Synced from Zotero by Walras. Do not edit by hand: this file gets rewritten.\n\n"

    private var projectSettings: [String: Any] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
    }

    @objc func configureZotero(_ sender: Any?) {
        guard ZoteroClient.isInstalled else {
            showAlert(ZoteroClient.Failure.notInstalled.message)
            return
        }
        setStatus(L("Conectando con Zotero…", "Connecting to Zotero…"), .secondaryLabelColor)
        ZoteroClient.collections { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                self.setStatus(L("Zotero no disponible", "Zotero unavailable"), .secondaryLabelColor)
                self.showAlert(failure.message)
            case .success(let collections):
                self.setStatus("", .secondaryLabelColor)
                self.askZoteroOptions(collections)
            }
        }
    }

    private func askZoteroOptions(_ collections: [ZoteroClient.Collection]) {
        let alert = NSAlert()
        alert.messageText = L("Sincronizar con Zotero", "Sync with Zotero")
        alert.informativeText = L("Walras va a mantener un archivo .bib de este proyecto igual a lo que tengas en Zotero.", "Walras will keep a .bib file in this project matching what you have in Zotero.")
        alert.addButton(withTitle: L("Sincronizar", "Sync"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 320, height: 26), pullsDown: false)
        popup.addItem(withTitle: L("Toda la biblioteca", "Entire Library"))
        popup.lastItem?.representedObject = ""
        for collection in collections {
            popup.addItem(withTitle: collection.name)
            popup.lastItem?.representedObject = collection.key
        }
        let savedCollection = projectSettings["zoteroCollection"] as? String ?? ""
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == savedCollection }) {
            popup.select(item)
        }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = projectSettings["zoteroTarget"] as? String ?? "zotero.bib"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        accessory.addSubview(popup)
        accessory.addSubview(field)
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("..") else {
            showAlert(L("Escribí un nombre de archivo dentro del proyecto, por ejemplo zotero.bib.", "Type a file name inside the project, for example zotero.bib."))
            return
        }
        if !name.lowercased().hasSuffix(".bib") { name += ".bib" }

        let target = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path), !isZoteroFile(target) {
            let confirm = NSAlert()
            confirm.messageText = L("“\(name)” ya existe y no lo creó Walras.", "“\(name)” already exists and wasn't created by Walras.")
            confirm.informativeText = L("Si seguís, se reemplaza su contenido por lo que tengas en Zotero.", "If you continue, its contents will be replaced with what you have in Zotero.")
            confirm.addButton(withTitle: L("Cancelar", "Cancel"))
            confirm.addButton(withTitle: L("Reemplazar", "Replace"))
            guard confirm.runModal() == .alertSecondButtonReturn else { return }
            try? Data(Self.zoteroHeader.utf8).write(to: target, options: .atomic)
        }

        storeSetting("zoteroTarget", name)
        storeSetting("zoteroCollection", popup.selectedItem?.representedObject as? String ?? "")
        syncZotero(quiet: false, explainUsage: true)
    }

    @objc func syncZoteroAction(_ sender: Any?) {
        if projectSettings["zoteroTarget"] == nil {
            configureZotero(sender)
        } else {
            syncZotero(quiet: false, explainUsage: false)
        }
    }

    /// Called when the app comes back to the front. It stays silent on failure,
    /// because Zotero being closed is the normal case.
    func syncZoteroIfConfigured() {
        guard projectSettings["zoteroTarget"] != nil else { return }
        if let last = lastZoteroSync, Date().timeIntervalSince(last) < 60 { return }
        syncZotero(quiet: true, explainUsage: false)
    }

    func isZoteroFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data.prefix(200), as: UTF8.self).hasPrefix(Self.zoteroHeader)
    }

    private func syncZotero(quiet: Bool, explainUsage: Bool) {
        guard !zoteroBusy, let name = projectSettings["zoteroTarget"] as? String else { return }
        zoteroBusy = true
        lastZoteroSync = Date()
        if !quiet { setStatus(L("Sincronizando con Zotero…", "Syncing with Zotero…"), .secondaryLabelColor) }
        let collection = projectSettings["zoteroCollection"] as? String ?? ""
        ZoteroClient.bibtex(collection: collection) { [weak self] result in
            guard let self else { return }
            self.zoteroBusy = false
            switch result {
            case .failure(let failure):
                if !quiet {
                    self.setStatus(L("Sin sincronizar", "Not synced"), .secondaryLabelColor)
                    self.showAlert(failure.message)
                }
            case .success(let bibtex):
                self.writeZotero(bibtex, name: name, quiet: quiet, explainUsage: explainUsage)
            }
        }
    }

    private func writeZotero(_ bibtex: String, name: String, quiet: Bool, explainUsage: Bool) {
        let target = root.appendingPathComponent(name)
        // Protects the user's file if it was replaced after being configured,
        // and a good file against an empty answer.
        if FileManager.default.fileExists(atPath: target.path), !isZoteroFile(target) {
            if !quiet { showAlert(L("“\(name)” ya no es el archivo que creó Walras, así que no lo toqué. Volvé a elegirlo en Configurar Zotero.", "“\(name)” is no longer the file Walras created, so it wasn't changed. Choose it again in Set Up Zotero.")) }
            return
        }
        guard !bibtex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !quiet {
                setStatus(L("Zotero no devolvió referencias", "Zotero returned no references"), .secondaryLabelColor)
                showAlert(L("Zotero no devolvió referencias para esa selección, así que no cambié el archivo.", "Zotero returned no references for that selection, so the file wasn't changed."))
            }
            return
        }

        let content = Data((Self.zoteroHeader + bibtex).utf8)
        let isNew = (try? Data(contentsOf: target)) != content
        do {
            if isNew {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, options: .atomic)
                citationIndex.reload(root: root)
                syncWithDisk()
            }
            if !quiet {
                setStatus(isNew ? L("Zotero sincronizado", "Zotero synced") : L("Zotero ya estaba al día", "Zotero was already up to date"), .secondaryLabelColor)
            }
            if explainUsage {
                let stem = (name as NSString).deletingPathExtension
                showAlert(L("Listo: tus referencias están en “\(name)”.", "Done: your references are in “\(name)”."),
                          detail: L("Para usarlas en el documento, agregá \\bibliography{\(stem)} con BibTeX, o \\addbibresource{\(name)} con biblatex.", "To use them in the document, add \\bibliography{\(stem)} with BibTeX, or \\addbibresource{\(name)} with biblatex."))
            }
        } catch {
            if !quiet { NSAlert(error: error).runModal() }
        }
    }
}
