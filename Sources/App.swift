import AppKit

@main
enum Entry {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var projects: [ProjectWindowController] = []
    private var welcome: WelcomeWindowController?
    private var keyMonitor: Any?
    let recentMenu = NSMenu(title: L("Abrir reciente", "Open Recent"))

    func applicationWillFinishLaunching(_ notification: Notification) {
        Compiler.removeLeftovers()
        AppearanceMode.apply()
        recentMenu.delegate = self
        NSApp.mainMenu = MainMenu.build(recentMenu: recentMenu)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Second shortcut for recompiling, the same one Overleaf uses.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.keyCode == 36,
               let project = NSApp.keyWindow?.windowController as? ProjectWindowController {
                project.recompile(nil)
                return nil
            }
            return event
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(jevonsChanged),
                                                            name: Notification.Name("io.github.sanarovaz.walras.jevonsChanged"), object: nil)
        if projects.isEmpty { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func jevonsChanged() {
        projects.forEach { $0.refreshJevonsNotes() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "walras" { openLink(url) } else { openProject(at: url) }
        }
    }

    /// walras://open?root=/path/to/project&file=main.tex&line=12, from Jevons.
    private func openLink(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let root = value("root") else { return }
        let rootURL = URL(fileURLWithPath: root)
        openProject(at: rootURL)
        guard let project = projects.first(where: { $0.root.standardizedFileURL.path == rootURL.standardizedFileURL.path }) else { return }
        project.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let file = value("file") {
            project.open(rootURL.appendingPathComponent(file).standardizedFileURL)
            if let line = value("line").flatMap(Int.init) { project.editor.go(toLine: line) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        projects.forEach { $0.prepareToClose() }
        var remaining = projects.count
        var isWaiting = false
        var didReply = false
        let reply = {
            guard !didReply else { return }
            didReply = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        projects.forEach {
            $0.finishPDFExports {
                remaining -= 1
                if remaining == 0, isWaiting { reply() }
            }
        }
        if remaining == 0 { return .terminateNow }
        // The last PDFs compile out of sight, and a stuck one can't hold the quit forever.
        isWaiting = true
        NSApp.windows.forEach { $0.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { reply() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Compiler.removeLeftovers()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        projects.forEach {
            $0.syncWithDisk()
            $0.syncZoteroIfConfigured()
            $0.refreshJevonsNotes()
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        projects.forEach {
            $0.saveAll(interactive: false)
            $0.editor.hideCompletion()
        }
    }

    // MARK: - About

    static let authorHandle = "@sanarovaz"
    static let authorURL = URL(string: "https://x.com/sanarovaz")!

    @objc func showAbout(_ sender: Any?) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSMutableAttributedString(string: L("Creada por ", "Created by "), attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        credits.append(NSAttributedString(string: Self.authorHandle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: Self.authorURL,
            .paragraphStyle: style,
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openAuthorPage(_ sender: Any?) {
        NSWorkspace.shared.open(Self.authorURL)
    }

    // MARK: - Appearance

    @objc func setAppearanceMode(_ sender: NSMenuItem) {
        if let mode = AppearanceMode(rawValue: sender.tag) { AppearanceMode.current = mode }
    }

    @objc func toggleDarkMode(_ sender: Any?) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        AppearanceMode.current = isDark ? .light : .dark
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setAppearanceMode(_:)) {
            item.state = item.tag == AppearanceMode.current.rawValue ? .on : .off
        }
        return true
    }

    // MARK: - Projects

    func showWelcome() {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.reload()
        welcome?.showWindow(nil)
        welcome?.window?.center()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Abrir", "Open")
        panel.message = L("Elegí la carpeta del proyecto o su archivo .tex principal", "Choose the project folder or its main .tex file")
        if panel.runModal() == .OK, let url = panel.url { openProject(at: url) }
    }

    @objc func newProject(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = L("Nuevo proyecto", "New Project")
        panel.prompt = L("Crear", "Create")
        panel.nameFieldLabel = L("Carpeta:", "Folder:")
        panel.nameFieldStringValue = L("Proyecto LaTeX", "LaTeX Project")
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let template = """
        \\documentclass[11pt]{article}
        \\usepackage[utf8]{inputenc}
        \\usepackage{amsmath, amssymb}

        \\title{\(L("Sin título", "Untitled"))}
        \\author{}
        \\date{\\today}

        \\begin{document}
        \\maketitle

        \(L("Escribí acá.", "Write here."))

        \\end{document}

        """
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(template.utf8).write(to: url.appendingPathComponent("main.tex"), options: .atomic)
            openProject(at: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func openProject(at url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            let alert = NSAlert()
            alert.messageText = L("No se encontró “\(url.lastPathComponent)”.", "“\(url.lastPathComponent)” was not found.")
            alert.runModal()
            removeRecent(url.path)
            return
        }
        let root = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let hint: URL? = (!isDirectory.boolValue && url.pathExtension.lowercased() == "tex") ? url : nil

        if let existing = projects.first(where: { $0.root.standardizedFileURL.path == root.standardizedFileURL.path }) {
            existing.window?.makeKeyAndOrderFront(nil)
            if let hint { existing.open(hint) }
            return
        }

        let controller = ProjectWindowController(root: root, requestedMain: hint)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.projects.removeAll { $0 === controller }
            if self.projects.isEmpty { self.showWelcome() }
        }
        projects.append(controller)
        controller.showWindow(nil)
        addRecent(root.path)
        welcome?.close()
    }

    // MARK: - Recents

    var recents: [String] { UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [] }

    private func addRecent(_ path: String) {
        var list = recents.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: "recentProjects")
    }

    private func removeRecent(_ path: String) {
        UserDefaults.standard.set(recents.filter { $0 != path }, forKey: "recentProjects")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for path in recents {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.toolTip = path
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: L("Sin proyectos recientes", "No Recent Projects"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            openProject(at: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Menu bar

enum MainMenu {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.tag = tag
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        top.submenu = menu
        return top
    }

    static func build(recentMenu: NSMenu) -> NSMenu {
        let bar = NSMenu()
        typealias P = ProjectWindowController

        let hideOthers = item(L("Ocultar otros", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        bar.addItem(submenu("Walras", [
            item(L("Acerca de Walras", "About Walras"), #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item(L("Ocultar Walras", "Hide Walras"), #selector(NSApplication.hide(_:)), "h"),
            hideOthers,
            item(L("Mostrar todo", "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("Salir de Walras", "Quit Walras"), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let recent = NSMenuItem(title: L("Abrir reciente", "Open Recent"), action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        bar.addItem(submenu(L("Archivo", "File"), [
            item(L("Nuevo proyecto…", "New Project…"), #selector(AppDelegate.newProject(_:)), "n", [.command, .shift]),
            item(L("Abrir proyecto…", "Open Project…"), #selector(AppDelegate.openDocument(_:)), "o"),
            recent,
            item(L("Abrir archivo rápido…", "Quick Open File…"), #selector(P.showQuickOpen(_:)), "p"),
            .separator(),
            item(L("Nuevo archivo…", "New File…"), #selector(P.newFileAction(_:)), "n"),
            item(L("Nueva carpeta…", "New Folder…"), #selector(P.newFolderAction(_:))),
            item(L("Agregar archivos…", "Add Files…"), #selector(P.addFilesAction(_:)), "a", [.command, .shift]),
            .separator(),
            item(L("Guardar", "Save"), #selector(P.saveAction(_:)), "s"),
            item(L("Historial de versiones…", "Version History…"), #selector(P.showVersionHistory(_:)), "h", [.command, .shift]),
            item(L("Descargar PDF…", "Download PDF…"), #selector(P.downloadPDF(_:)), "d"),
            item(L("Subir a GitHub…", "Push to GitHub…"), #selector(P.pushToGitHub(_:)), "u", [.command, .shift]),
            .separator(),
            item(L("Cerrar pestaña", "Close Tab"), #selector(P.closeCurrentTab(_:)), "w"),
            item(L("Cerrar ventana", "Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ]))

        bar.addItem(submenu(L("Edición", "Edit"), [
            item(L("Deshacer", "Undo"), Selector(("undo:")), "z"),
            item(L("Rehacer", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cortar", "Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copiar", "Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Pegar", "Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Seleccionar todo", "Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L("Negrita", "Bold"), #selector(P.formatBold(_:)), "b"),
            item(L("Cursiva", "Italic"), #selector(P.formatItalic(_:)), "i"),
            .separator(),
            item(L("Copiar como imagen", "Copy as Image"), #selector(P.copySelectionAsImage(_:)), "c", [.command, .control]),
            item(L("Copiar como imagen oscura", "Copy as Dark Image"), #selector(P.copySelectionAsDarkImage(_:)), "c", [.command, .control, .shift]),
            .separator(),
            item(L("Buscar…", "Find…"), #selector(NSResponder.performTextFinderAction(_:)), "f",
                 tag: NSTextFinder.Action.showFindInterface.rawValue),
            item(L("Buscar y reemplazar…", "Find and Replace…"), #selector(NSResponder.performTextFinderAction(_:)), "f", [.command, .option],
                 tag: NSTextFinder.Action.showReplaceInterface.rawValue),
            item(L("Buscar siguiente", "Find Next"), #selector(NSResponder.performTextFinderAction(_:)), "g",
                 tag: NSTextFinder.Action.nextMatch.rawValue),
            item(L("Buscar anterior", "Find Previous"), #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift],
                 tag: NSTextFinder.Action.previousMatch.rawValue),
            .separator(),
            item(L("Buscar en el proyecto…", "Find in Project…"), #selector(P.searchInProject(_:)), "f", [.command, .shift]),
            .separator(),
            submenu(L("Ortografía", "Spelling"), [
                item(L("Desactivada", "Off"), #selector(P.setSpellLanguage(_:)), tag: 0),
                item(L("Español", "Spanish"), #selector(P.setSpellLanguage(_:)), tag: 1),
                item(L("Inglés", "English"), #selector(P.setSpellLanguage(_:)), tag: 2),
            ]),
        ]))

        var engineItems: [NSMenuItem] = []
        for (index, engine) in Engine.allCases.enumerated() {
            engineItems.append(item(engine.title, #selector(P.setEngine(_:)), tag: index))
        }
        let engineMenu = submenu(L("Motor", "Engine"), engineItems)

        var themeItems: [NSMenuItem] = []
        for (index, theme) in EditorTheme.all.enumerated() {
            themeItems.append(item(theme.name, #selector(P.setTheme(_:)), tag: index))
        }

        bar.addItem(submenu(L("Compilar", "Compile"), [
            item(L("Recompilar", "Recompile"), #selector(P.recompile(_:)), "r"),
            item(L("Recompilar desde cero", "Recompile from Scratch"), #selector(P.recompileFromScratch(_:)), "r", [.command, .shift]),
            item(L("Detener", "Stop"), #selector(P.stopCompile(_:)), "."),
            .separator(),
            item(L("Compilar al guardar (⌘S)", "Compile on Save (⌘S)"), #selector(P.toggleCompileOnSave(_:))),
            engineMenu,
            .separator(),
            item(L("Mostrar u ocultar el log", "Show or Hide Log"), #selector(P.toggleLog(_:)), "l"),
            item(L("Copiar errores", "Copy Errors"), #selector(P.copyErrors(_:)), "e", [.command, .shift]),
            item(L("Copiar log completo", "Copy Full Log"), #selector(P.copyFullLog(_:))),
        ]))

        bar.addItem(submenu(L("Bibliografía", "Bibliography"), [
            item(L("Agregar referencia…", "Add Reference…"), #selector(P.showPaperSearch(_:)), "b", [.command, .shift]),
            .separator(),
            item(L("Sincronizar con Zotero", "Sync with Zotero"), #selector(P.syncZoteroAction(_:)), "z", [.command, .option]),
            item(L("Configurar Zotero…", "Set Up Zotero…"), #selector(P.configureZotero(_:))),
        ]))

        bar.addItem(submenu(L("Visualización", "View"), [
            item(L("Mostrar u ocultar la barra lateral", "Show or Hide Sidebar"), #selector(P.toggleSidebarAction(_:)), "s", [.command, .control]),
            item(L("Archivos", "Files"), #selector(P.showFilesTab(_:)), "1", [.command, .option]),
            item(L("Índice", "Outline"), #selector(P.showIndexTab(_:)), "2", [.command, .option]),
            item(L("Modo foco", "Focus Mode"), #selector(P.toggleFocusMode(_:)), "\r", [.command, .shift]),
            item(L("Modo oscuro", "Dark Mode"), #selector(AppDelegate.toggleDarkMode(_:)), "d", [.command, .shift]),
            submenu(L("Apariencia", "Appearance"), AppearanceMode.allCases.map {
                item($0.title, #selector(AppDelegate.setAppearanceMode(_:)), tag: $0.rawValue)
            }),
            submenu(L("Tema del editor", "Editor Theme"), themeItems),
            .separator(),
            item(L("Acercar PDF", "Zoom In on PDF"), #selector(P.zoomInPDF(_:)), "+"),
            item(L("Alejar PDF", "Zoom Out of PDF"), #selector(P.zoomOutPDF(_:)), "-"),
            item(L("Ajustar PDF al ancho", "Fit PDF to Width"), #selector(P.zoomFitPDF(_:)), "0"),
            .separator(),
            item(L("Letra del editor más grande", "Larger Editor Text"), #selector(P.biggerFont(_:)), "+", [.command, .option]),
            item(L("Letra del editor más chica", "Smaller Editor Text"), #selector(P.smallerFont(_:)), "-", [.command, .option]),
            .separator(),
            item(L("Pantalla completa", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        let window = submenu(L("Ventana", "Window"), [
            item(L("Minimizar", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Claude", #selector(P.toggleClaudePanel(_:)), "c", [.command, .option]),
            item(L("Abrir paper citado en Jevons", "Open Cited Paper in Jevons"), #selector(P.openCitedPaperInJevons(_:)), "j", [.command, .option, .shift]),
            .separator(),
            item(L("Pestaña siguiente", "Next Tab"), #selector(P.nextTab(_:)), "\t", [.control]),
            item(L("Pestaña anterior", "Previous Tab"), #selector(P.previousTab(_:)), "\t", [.control, .shift]),
        ])
        bar.addItem(window)
        NSApp.windowsMenu = window.submenu
        return bar
    }
}

// MARK: - Welcome window

final class WelcomeWindowController: NSWindowController {
    private let recentStack = NSStackView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let title = NSTextField(labelWithString: "Walras")
        title.font = .systemFont(ofSize: 24, weight: .semibold)

        let byline = NSButton(title: L("por ", "by ") + AppDelegate.authorHandle, target: NSApp.delegate,
                              action: #selector(AppDelegate.openAuthorPage(_:)))
        byline.isBordered = false
        byline.font = .systemFont(ofSize: 11)
        byline.contentTintColor = .secondaryLabelColor
        byline.toolTip = "x.com/sanarovaz"

        let newButton = NSButton(title: L("Nuevo proyecto", "New Project"), target: NSApp.delegate, action: #selector(AppDelegate.newProject(_:)))
        let openButton = NSButton(title: L("Abrir proyecto", "Open Project"), target: NSApp.delegate, action: #selector(AppDelegate.openDocument(_:)))
        openButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [newButton, openButton])
        buttons.spacing = 10

        let recentTitle = NSTextField(labelWithString: L("Recientes", "Recent"))
        recentTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        recentTitle.textColor = .secondaryLabelColor

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2

        let stack = NSStackView(views: [icon, title, byline, buttons, recentTitle, recentStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(26, after: buttons)
        stack.setCustomSpacing(6, after: recentTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let recents = Array(delegate.recents.prefix(6))
        if recents.isEmpty {
            let label = NSTextField(labelWithString: L("Todavía no abriste ningún proyecto.", "You haven't opened a project yet."))
            label.textColor = .tertiaryLabelColor
            recentStack.addArrangedSubview(label)
        }
        for path in recents {
            let button = NSButton(title: (path as NSString).lastPathComponent, target: self, action: #selector(openRecent(_:)))
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
            button.identifier = NSUserInterfaceItemIdentifier(path)
            button.toolTip = path
            recentStack.addArrangedSubview(button)
        }
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        (NSApp.delegate as? AppDelegate)?.openProject(at: URL(fileURLWithPath: path))
    }
}
