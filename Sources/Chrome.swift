import AppKit

/// A view that fills itself with a colour of the current theme, at draw time,
/// so it follows both theme changes and the light and dark appearances.
final class ThemedBackgroundView: NSView {
    private let color: (EditorTheme) -> NSColor

    init(_ color: @escaping (EditorTheme) -> NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        color(EditorTheme.current).setFill()
        bounds.fill()
    }
}

final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor { EditorTheme.current.separator }
    override var dividerThickness: CGFloat { 1 }
}

/// A rounded selection in the theme's colour, instead of the system's blue.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        EditorTheme.current.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Small icon button for the sidebar's three views.
final class SideTabButton: NSButton {
    var isCurrent = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCurrent {
            EditorTheme.current.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// The window's only bar, at the height of a normal title bar: the project's name
/// in the centre and a status that fades once it has been read.
final class WindowBar: NSView {
    static let height: CGFloat = 28

    private let projectLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSImageView()
    private let spinner = NSProgressIndicator()
    private let statusStack = NSStackView()
    private var fadeTimer: Timer?
    private var isBusy = false
    private static let lightsInset: CGFloat = 78

    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        for view in [spinner, statusDot, statusLabel] as [NSView] { statusStack.addArrangedSubview(view) }

        projectLabel.font = .systemFont(ofSize: 12, weight: .medium)
        projectLabel.lineBreakMode = .byTruncatingTail
        projectLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 5, weight: .regular))
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusStack.spacing = 5
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(projectLabel)
        addSubview(statusStack)
        NSLayoutConstraint.activate([
            projectLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            projectLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            projectLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.lightsInset),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: projectLabel.trailingAnchor, constant: 12),
            statusStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        EditorTheme.current.bar.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        NotificationCenter.default.post(name: .editorThemeChanged, object: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
    }

    func refreshColors() {
        let theme = EditorTheme.current
        projectLabel.textColor = theme.icon
        needsDisplay = true
    }

    func setTitle(project: String) {
        projectLabel.stringValue = project
    }

    /// Errors stay until the next compilation; everything else fades after a few seconds.
    func setStatus(_ text: String, dot: NSColor?, textColor: NSColor, isSticky: Bool) {
        fadeTimer?.invalidate()
        statusLabel.stringValue = text
        statusLabel.textColor = textColor
        statusDot.isHidden = dot == nil || text.isEmpty || isBusy
        statusDot.contentTintColor = dot
        statusStack.alphaValue = 1
        guard !isSticky, !isBusy, !text.isEmpty else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self?.statusStack.animator().alphaValue = 0
            }
        }
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy {
            fadeTimer?.invalidate()
            statusStack.alphaValue = 1
            spinner.startAnimation(nil)
            statusDot.isHidden = true
        } else {
            spinner.stopAnimation(nil)
        }
    }

}

/// The bar on top and the split view below it.
final class RootViewController: NSViewController {
    let bar: WindowBar
    var onLogoClick: (() -> Void)?
    private let content: NSViewController
    private var logo: NSButton!
    private var barHeight: NSLayoutConstraint!

    init(bar: WindowBar, content: NSViewController) {
        self.bar = bar
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1380, height: 860))
        addChild(content)
        let inner = content.view
        bar.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(inner)
        root.addSubview(bar)

        // Lives above the columns, so it stays in place when the sidebar opens or closes.
        let image = Bundle.main.image(forResource: "WindowLogo") ?? NSApp.applicationIconImage ?? NSImage()
        logo = NSButton(image: image, target: self, action: #selector(logoPressed))
        logo.isBordered = false
        logo.imagePosition = .imageOnly
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.toolTip = L("Mostrar u ocultar la barra lateral (⌃⌘S)", "Show or hide the sidebar (⌃⌘S)")
        logo.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(logo)
        barHeight = bar.heightAnchor.constraint(equalToConstant: WindowBar.height)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barHeight,
            inner.topAnchor.constraint(equalTo: bar.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            logo.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            logo.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            logo.widthAnchor.constraint(equalToConstant: 32),
            logo.heightAnchor.constraint(equalToConstant: 32),
        ])
        view = root
    }

    @objc private func logoPressed() {
        onLogoClick?()
    }

    func setBarHidden(_ hidden: Bool) {
        barHeight.constant = hidden ? 0 : WindowBar.height
        bar.isHidden = hidden
        logo.isHidden = hidden
    }
}
