import AppKit
import Quartz

extension NSAttributedString.Key {
    /// Marks the text of a line LaTeX complained about, so that the mark moves with the text.
    static let walrasError = NSAttributedString.Key("WalrasCompileError")
}

/// One open text file. Each keeps its own storage and undo history, so that
/// moving between files does not lose the place or mix up undo.
final class TextBuffer {
    var url: URL
    let storage: NSTextStorage
    let undo = UndoManager()
    var encoding: String.Encoding
    var modified: Date?
    /// The file's bytes as of the last read or save, to tell real outside edits from
    /// a new date alone, as left by sync apps or a copy that keeps the content.
    private var knownData = Data()
    var dirty = false
    var selection = NSRange(location: 0, length: 0)
    var scrollOrigin = NSPoint.zero

    init?(url: URL, font: NSFont) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
            encoding = .utf8
        } else if let latin = String(data: data, encoding: .windowsCP1252) {
            text = latin
            encoding = .windowsCP1252
        } else {
            return nil
        }
        self.url = url
        storage = NSTextStorage(string: text, attributes: TextBuffer.attributes(font))
        modified = TextBuffer.modificationDate(of: url)
        knownData = data
    }

    static let lineSpacing: CGFloat = 6

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }()

    static func attributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: EditorTheme.current.text, .paragraphStyle: paragraphStyle]
    }

    static func modificationDate(of url: URL) -> Date? {
        // URL resource values can be cached, and a stale date right after saving would
        // look like an outside edit later on. This always asks the file system.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    var changedOnDisk: Bool {
        guard let onDisk = TextBuffer.modificationDate(of: url), onDisk != modified else { return false }
        if let data = try? Data(contentsOf: url), data == knownData {
            modified = onDisk
            return false
        }
        return true
    }

    func write() throws {
        guard let data = storage.string.data(using: encoding, allowLossyConversion: false)
                ?? storage.string.data(using: .utf8) else { return }
        try data.write(to: url, options: .atomic)
        modified = TextBuffer.modificationDate(of: url)
        knownData = data
        dirty = false
    }

    func reloadFromDisk(font: NSFont) {
        guard let fresh = TextBuffer(url: url, font: font) else { return }
        undo.removeAllActions()
        storage.setAttributedString(fresh.storage)
        encoding = fresh.encoding
        modified = fresh.modified
        knownData = fresh.knownData
        dirty = false
    }

    func clearErrorMarks() {
        storage.removeAttribute(.walrasError, range: NSRange(location: 0, length: storage.length))
    }

    func markError(line: Int, message: String) {
        let text = storage.string as NSString
        guard line >= 1, text.length > 0 else { return }
        var start = 0
        var current = 1
        while current < line, start < text.length {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            current += 1
        }
        guard current == line, start < text.length else { return }
        storage.addAttribute(.walrasError, value: message, range: text.lineRange(for: NSRange(location: start, length: 0)))
    }
}

final class LineNumberRuler: NSRulerView, NSViewToolTipOwner {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var errorAreas: [(rect: NSRect, message: String)] = []

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 54
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func textChanged() {
        var starts = [0]
        guard let textView else { return }
        var index = 0
        for unit in textView.string.utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        lineStarts = starts
        needsDisplay = true
    }

    private func lineIndex(forCharacter character: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= character { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func errorMessage(inLine line: Int, storage: NSTextStorage) -> String? {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : storage.length
        guard start < storage.length else { return nil }
        var found: String?
        storage.enumerateAttribute(.walrasError, in: NSRange(location: start, length: min(end, storage.length) - start), options: []) { value, _, stop in
            if let message = value as? String {
                found = message
                stop.pointee = true
            }
        }
        return found
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        errorAreas.first { $0.rect.contains(point) }?.message ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        // A line half scrolled out would otherwise paint its number over the tab bar:
        // since macOS 14, views no longer clip their drawing to their bounds.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        EditorTheme.current.background.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = convert(NSPoint.zero, from: textView)
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: EditorTheme.current.gutterText,
        ]
        let inset = textView.textContainerOrigin.y
        let storage = textView.textStorage
        var newErrorAreas: [(rect: NSRect, message: String)] = []

        func drawNumber(_ number: Int, y: CGFloat, height: CGFloat) {
            var lineAttributes = attributes
            let message = storage.flatMap { errorMessage(inLine: number - 1, storage: $0) }
            if message != nil { lineAttributes[.foregroundColor] = NSColor.systemRed }
            let label = String(number) as NSString
            let size = label.size(withAttributes: lineAttributes)
            let textY = y + origin.y + inset + (height - TextBuffer.lineSpacing - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 14, y: textY), withAttributes: lineAttributes)
            if let message {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: ruleThickness - size.width - 24, y: textY + size.height / 2 - 3, width: 6, height: 6)).fill()
                newErrorAreas.append((NSRect(x: 0, y: y + origin.y + inset, width: bounds.width, height: height), message))
            }
        }

        var line = lineIndex(forCharacter: characters.location)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            if start < (textView.string as NSString).length {
                let glyph = layout.glyphIndexForCharacter(at: start)
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                drawNumber(line + 1, y: fragment.minY, height: fragment.height)
            } else {
                let fragment = layout.extraLineFragmentRect
                if fragment.height > 0 {
                    drawNumber(line + 1, y: fragment.minY, height: fragment.height)
                }
            }
            line += 1
        }

        if !errorAreas.isEmpty || !newErrorAreas.isEmpty {
            removeAllToolTips()
            for area in newErrorAreas { addToolTip(area.rect, owner: self, userData: nil) }
        }
        errorAreas = newErrorAreas
    }
}

/// Handles the LaTeX typing helpers. All of them apply only to typed text, never to pasted text.
final class EditorTextView: NSTextView {
    /// Returns LaTeX to insert when the clipboard holds an image, or nil for a normal paste.
    var imagePasteHandler: ((NSPasteboard) -> String?)?
    /// Called after a helper moved the caret, once the text is in its final state.
    var onCaretSettled: (() -> Void)?
    var onFocus: (() -> Void)?
    var onCommandClick: ((_ line: Int) -> Void)?
    /// ⌘-click on a citation. Returns true if there was one where the click landed.
    var onCitationClick: ((_ location: Int) -> Bool)?
    var isLatexEditing = false

    private static let notFound = NSRange(location: NSNotFound, length: 0)
    private static let beginPattern = try! NSRegularExpression(pattern: "\\\\begin\\{([^{}]+)\\}$")

    // MARK: - Moving lines and multiple carets

    /// Carets beyond the main one, which stays the text view's own selection. Each is a plain
    /// caret: AppKit keeps one insertion point, so these are drawn and edited here.
    private var extraCarets: [Int] = []
    private var caretColumnX: CGFloat?
    private var isApplyingCarets = false
    var hasExtraCarets: Bool { !extraCarets.isEmpty }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let isUp = event.keyCode == 126
        if isUp || event.keyCode == 125 {
            if flags == .option {
                moveSelectedLines(up: isUp)
                return
            }
            if flags == [.control, .option] {
                addCaret(up: isUp)
                return
            }
        }
        super.keyDown(with: event)
    }

    /// ⌥↑ and ⌥↓: swaps the selected lines with the line next to them, as one undoable change.
    private func moveSelectedLines(up: Bool) {
        guard let storage = textStorage else { return }
        let text = string as NSString
        let selection = selectedRange()
        var probe = selection
        if probe.length > 0, text.character(at: NSMaxRange(probe) - 1) == 10 { probe.length -= 1 }
        let block = text.lineRange(for: probe)
        let neighbor: NSRange
        if up {
            guard block.location > 0 else { return }
            neighbor = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        } else {
            guard NSMaxRange(block) < text.length else { return }
            neighbor = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        }
        let first = up ? neighbor : block
        let second = up ? block : neighbor
        let top = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: first))
        let bottom = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: second))
        // The file's last line may have no line break of its own: it stays at the end.
        if !bottom.string.hasSuffix("\n") {
            bottom.append(NSAttributedString(string: "\n", attributes: typingAttributes))
            top.deleteCharacters(in: NSRange(location: top.length - 1, length: 1))
        }
        let whole = NSRange(location: first.location, length: first.length + second.length)
        let swapped = NSMutableAttributedString(attributedString: bottom)
        swapped.append(top)
        guard shouldChangeText(in: whole, replacementString: swapped.string) else { return }
        storage.replaceCharacters(in: whole, with: swapped)
        let location = up ? selection.location - neighbor.length : selection.location + bottom.length
        setSelectedRange(NSRange(location: location, length: selection.length))
        didChangeText()
        scrollRangeToVisible(selectedRange())
    }

    private func caretPlace(at location: Int) -> (x: CGFloat, fragment: NSRect) {
        guard let layout = layoutManager, let container = textContainer else { return (0, .zero) }
        let length = (string as NSString).length
        if location >= length {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { return (extra.minX + container.lineFragmentPadding, extra) }
            guard length > 0 else { return (container.lineFragmentPadding, .zero) }
            let glyph = layout.glyphIndexForCharacter(at: length - 1)
            return (layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX,
                    layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
        }
        let glyph = layout.glyphIndexForCharacter(at: location)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (fragment.minX + layout.location(forGlyphAt: glyph).x, fragment)
    }

    /// The position on the visual line above or below, or nil at either end of the text.
    private func caretNeighbor(of location: Int, up: Bool, x: CGFloat) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let fragment = caretPlace(at: location).fragment
        let y = up ? fragment.minY - 1 : fragment.maxY + 1
        let text = string as NSString
        guard y >= 0 else { return nil }
        let extra = layout.extraLineFragmentRect
        if extra.height > 0, y >= extra.minY, y < extra.maxY { return text.length }
        guard y < layout.usedRect(for: container).maxY else { return nil }
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: NSPoint(x: x, y: y), in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        if index < text.length, text.character(at: index) == 10 { return index }
        return min(text.length, fraction > 0.5 ? index + 1 : index)
    }

    /// ⌃⌥↑ and ⌃⌥↓: one more caret past the topmost or bottommost one, keeping the column.
    private func addCaret(up: Bool) {
        if extraCarets.isEmpty { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        let carets = [selectedRange().location] + extraCarets
        let base = up ? carets.min()! : carets.max()!
        let x = caretColumnX ?? caretPlace(at: base).x
        caretColumnX = x
        guard let new = caretNeighbor(of: base, up: up, x: x), !carets.contains(new) else { return }
        extraCarets.append(new)
        scrollRangeToVisible(NSRange(location: new, length: 0))
        needsDisplay = true
    }

    private func clearExtraCarets() {
        guard !extraCarets.isEmpty else { return }
        extraCarets = []
        caretColumnX = nil
        needsDisplay = true
    }

    /// Anything that changes the selection or the text from elsewhere ends the multiple carets:
    /// a click, ⌘A, undo, switching files.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isApplyingCarets { clearExtraCarets() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        restartBlink()
    }

    override func didChangeText() {
        if !isApplyingCarets { clearExtraCarets() }
        super.didChangeText()
        restartBlink()
    }

    /// AppKit's caret spans the whole line fragment, spacing below the text included, and
    /// can't be resized since macOS 14. So every caret here is drawn by this view.
    var caretColor: NSColor = .textColor {
        didSet {
            insertionPointColor = .clear
            needsDisplay = true
        }
    }
    private var caretIsOn = true
    private var blinkTimer: Timer?

    override var shouldDrawInsertionPoint: Bool { false }

    private var visibleCarets: [Int] {
        guard window?.firstResponder === self, window?.isKeyWindow == true else { return [] }
        let selection = selectedRange()
        return selection.length == 0 ? [selection.location] + extraCarets : extraCarets
    }

    private func caretRect(at location: Int) -> NSRect {
        let place = caretPlace(at: location)
        let origin = textContainerOrigin
        let height = layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) ?? place.fragment.height
        return NSRect(x: place.x + origin.x, y: place.fragment.minY + origin.y, width: 1.5, height: height)
    }

    /// The caret stays lit while the user acts on it, and blinks once they stop.
    private func restartBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        caretIsOn = true
        needsDisplay = true
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretIsOn.toggle()
            for location in self.visibleCarets { self.setNeedsDisplay(self.caretRect(at: location).insetBy(dx: -1, dy: -1)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartBlink()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard caretIsOn else { return }
        caretColor.setFill()
        for location in visibleCarets { caretRect(at: location).fill() }
    }

    /// Applies one edit per caret as a single undoable change. The first edit is the main caret's.
    private func applyCaretEdits(_ edits: [(range: NSRange, text: String)]) {
        guard let storage = textStorage, let primary = edits.first else { return }
        var ordered: [(range: NSRange, text: String, isPrimary: Bool)] = edits.enumerated()
            .map { (range: $0.element.range, text: $0.element.text, isPrimary: $0.offset == 0) }
            .sorted { $0.range.location < $1.range.location }
        var end = 0
        for index in ordered.indices {
            let range = ordered[index].range
            let location = max(range.location, end)
            ordered[index].range = NSRange(location: location, length: max(0, NSMaxRange(range) - location))
            end = NSMaxRange(ordered[index].range)
        }
        guard let start = ordered.first?.range.location else { return }
        let span = NSRange(location: start, length: end - start)
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: span))
        for edit in ordered.reversed() {
            replacement.replaceCharacters(in: NSRange(location: edit.range.location - start, length: edit.range.length),
                                          with: NSAttributedString(string: edit.text, attributes: typingAttributes))
        }
        guard shouldChangeText(in: span, replacementString: replacement.string) else { return }

        var delta = 0
        var primaryCaret = primary.range.location
        var others: [Int] = []
        for edit in ordered {
            let length = (edit.text as NSString).length
            let caret = edit.range.location + delta + length
            if edit.isPrimary { primaryCaret = caret } else { others.append(caret) }
            delta += length - edit.range.length
        }
        isApplyingCarets = true
        storage.replaceCharacters(in: span, with: replacement)
        setSelectedRange(NSRange(location: primaryCaret, length: 0))
        extraCarets = Array(Set(others)).filter { $0 != primaryCaret }
        caretColumnX = nil
        didChangeText()
        isApplyingCarets = false
        scrollRangeToVisible(NSRange(location: primaryCaret, length: 0))
        needsDisplay = true
    }

    private func deleteAtCarets(forward: Bool) {
        let text = string as NSString
        let carets = [selectedRange().location] + extraCarets
        applyCaretEdits(carets.map { caret -> (range: NSRange, text: String) in
            let nothing = NSRange(location: caret, length: 0)
            if forward {
                return (range: caret < text.length ? text.rangeOfComposedCharacterSequence(at: caret) : nothing, text: "")
            }
            return (range: caret > 0 ? text.rangeOfComposedCharacterSequence(at: caret - 1) : nothing, text: "")
        })
    }

    private func moveCarets(_ transform: (Int) -> Int) {
        let primary = transform(selectedRange().location)
        let others = Array(Set(extraCarets.map(transform))).filter { $0 != primary }
        isApplyingCarets = true
        setSelectedRange(NSRange(location: primary, length: 0))
        isApplyingCarets = false
        extraCarets = others
        caretColumnX = nil
        scrollRangeToVisible(NSRange(location: primary, length: 0))
        needsDisplay = true
    }

    private func visualLineEnds(of location: Int) -> (start: Int, end: Int) {
        let text = string as NSString
        guard let layout = layoutManager, location < text.length else { return (location, location) }
        var glyphs = NSRange()
        layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: &glyphs)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var end = NSMaxRange(characters)
        if end > characters.location, text.character(at: end - 1) == 10 { end -= 1 }
        return (characters.location, end)
    }

    override func doCommand(by selector: Selector) {
        guard !extraCarets.isEmpty else {
            super.doCommand(by: selector)
            return
        }
        let text = string as NSString
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            clearExtraCarets()
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)):
            moveCarets { $0 > 0 ? text.rangeOfComposedCharacterSequence(at: $0 - 1).location : 0 }
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
            moveCarets { $0 < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: $0)) : $0 }
        case #selector(NSResponder.moveUp(_:)):
            moveCarets { caretNeighbor(of: $0, up: true, x: caretPlace(at: $0).x) ?? $0 }
        case #selector(NSResponder.moveDown(_:)):
            moveCarets { caretNeighbor(of: $0, up: false, x: caretPlace(at: $0).x) ?? $0 }
        case #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordBackward(_:)):
            moveCarets { textStorage?.nextWord(from: $0, forward: false) ?? $0 }
        case #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordForward(_:)):
            moveCarets { textStorage?.nextWord(from: $0, forward: true) ?? $0 }
        case #selector(NSResponder.moveToLeftEndOfLine(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)):
            moveCarets { visualLineEnds(of: $0).start }
        case #selector(NSResponder.moveToRightEndOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
            moveCarets { visualLineEnds(of: $0).end }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            super.doCommand(by: selector)
        default:
            clearExtraCarets()
            super.doCommand(by: selector)
        }
    }

    override func deleteForward(_ sender: Any?) {
        if extraCarets.isEmpty {
            super.deleteForward(sender)
        } else {
            deleteAtCarets(forward: true)
        }
    }

    /// A dead key shows its accent at the main caret only, but still moves the carets after it.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !extraCarets.isEmpty else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        let oldLength = hasMarkedText() ? markedRange().length : 0
        let primary = hasMarkedText() ? markedRange().location : self.selectedRange().location
        let newLength = (string as? NSAttributedString)?.length ?? (string as? String).map { ($0 as NSString).length } ?? 0
        isApplyingCarets = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        isApplyingCarets = false
        extraCarets = extraCarets.map { $0 > primary ? $0 + newLength - oldLength : $0 }
        needsDisplay = true
    }

    /// Text typed on a marked line isn't part of the error LaTeX reported.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var clean = newValue
            clean[.walrasError] = nil
            super.typingAttributes = clean
        }
    }

    /// Leaves room to scroll until only the last line remains on screen, whatever size this
    /// was asked to be: the height always comes from the text, so it never adds up.
    override func setFrameSize(_ newSize: NSSize) {
        guard let layout = layoutManager, let container = textContainer,
              let visibleHeight = enclosingScrollView?.contentSize.height else {
            super.setFrameSize(newSize)
            return
        }
        let lineHeight = layout.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) + TextBuffer.lineSpacing
        let lastLineTop = textContainerOrigin.y + layout.usedRect(for: container).height - lineHeight
        super.setFrameSize(NSSize(width: newSize.width, height: max(visibleHeight, lastLineTop + visibleHeight)))
    }

    private func caretLineY() -> CGFloat? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        let length = (string as NSString).length
        var location = selectedRange().location
        if location >= length {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { return extra.minY + textContainerOrigin.y }
            if length == 0 { return textContainerOrigin.y }
            location = length - 1
        }
        let glyph = layout.glyphIndexForCharacter(at: location)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
    }

    /// Runs a line break or its removal so that the caret's line stays at the same height and
    /// what's above moves instead. A caret off screen scrolls into view as usual.
    private func keepingCaretHeight(_ insert: () -> Void) {
        guard let scroll = enclosingScrollView, let lineY = caretLineY() else {
            insert()
            return
        }
        let clip = scroll.contentView
        let offset = lineY - clip.bounds.origin.y
        insert()
        guard offset >= 0, offset < clip.bounds.height, let newY = caretLineY() else { return }
        sizeToFit()
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, newY - offset)))
        scroll.reflectScrolledClipView(clip)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        restartBlink()
        return became
    }

    /// ⌘-click on the code shows that line in the PDF.
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), isLatexEditing, let onCommandClick else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        if onCitationClick?(index) == true { return }
        let upToCaret = (string as NSString).substring(to: min(index, (string as NSString).length))
        onCommandClick(upToCaret.utf16.reduce(1) { $0 + ($1 == 10 ? 1 : 0) })
    }

    override func paste(_ sender: Any?) {
        if !extraCarets.isEmpty, let text = NSPasteboard.general.string(forType: .string) {
            insertText(text, replacementRange: Self.notFound)
            return
        }
        if let snippet = imagePasteHandler?(NSPasteboard.general) {
            super.insertText(snippet, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let incoming = (string as? String) ?? (string as? NSAttributedString)?.string
        if !extraCarets.isEmpty, let incoming {
            let main = hasMarkedText() ? markedRange() : selectedRange()
            if hasMarkedText() {
                isApplyingCarets = true
                unmarkText()
                isApplyingCarets = false
            }
            var edits: [(range: NSRange, text: String)] = [(range: main, text: incoming)]
            for caret in extraCarets { edits.append((range: NSRange(location: caret, length: 0), text: incoming)) }
            applyCaretEdits(edits)
            return
        }
        guard isLatexEditing, replacementRange.location == NSNotFound, !hasMarkedText(),
              let typed = incoming, typed.utf16.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let selection = selectedRange()
        let text = self.string as NSString
        let after = NSMaxRange(selection)
        let next: unichar = after < text.length ? text.character(at: after) : 0
        let previous: unichar = selection.location > 0 ? text.character(at: selection.location - 1) : 0
        let isEscaped = previous == 92 && (selection.location < 2 || text.character(at: selection.location - 2) != 92)
        let nextAllowsPair = next == 0 || next == 10 || next == 32 || next == 9 || next == 125
            || next == 41 || next == 93 || next == 44 || next == 46 || next == 59 || next == 36

        switch typed {
        case "{":
            if selection.length > 0 {
                wrapSelection(selection, open: "{", close: "}")
                return
            }
            if isEscaped {
                insertPair("{\\}", caretBack: 2)
                return
            }
            if nextAllowsPair {
                insertPair("{}", caretBack: 1)
                return
            }
        case "}":
            if selection.length == 0, next == 125, !isEscaped {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                closeEnvironmentIfNeeded()
                onCaretSettled?()
                return
            }
            super.insertText(string, replacementRange: replacementRange)
            closeEnvironmentIfNeeded()
            return
        case "$":
            if isEscaped { break }
            if selection.length > 0 {
                wrapSelection(selection, open: "$", close: "$")
                return
            }
            if next == 36 {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                onCaretSettled?()
                return
            }
            if !isInsideInlineMath(before: selection.location, in: text), nextAllowsPair, next != 36 {
                insertPair("$$", caretBack: 1)
                return
            }
        default:
            break
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    private func insertPair(_ pair: String, caretBack: Int) {
        super.insertText(pair, replacementRange: Self.notFound)
        setSelectedRange(NSRange(location: selectedRange().location - caretBack, length: 0))
        onCaretSettled?()
    }

    private func wrapSelection(_ selection: NSRange, open: String, close: String) {
        let inner = (string as NSString).substring(with: selection)
        super.insertText(open + inner + close, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
        onCaretSettled?()
    }

    /// An odd number of unescaped $ earlier on the line means this one closes the formula.
    private func isInsideInlineMath(before location: Int, in text: NSString) -> Bool {
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        var count = 0
        var index = lineStart
        while index < location {
            let unit = text.character(at: index)
            if unit == 92 {
                index += 2
                continue
            }
            if unit == 37 { break }
            if unit == 36 { count += 1 }
            index += 1
        }
        return count % 2 == 1
    }

    /// After \begin{x}, adds \end{x} on the next line unless the document is already
    /// balanced. The caret stays on the \begin line, so that optional arguments like
    /// \begin{tabular}{cc} can still be typed; pressing return opens the inner line.
    func closeEnvironmentIfNeeded() {
        guard isLatexEditing else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let rest = text.substring(with: NSRange(location: selection.location, length: NSMaxRange(line) - selection.location))
        guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let match = Self.beginPattern.firstMatch(in: before, options: [],
                                                       range: NSRange(location: 0, length: (before as NSString).length))
        else { return }
        let name = (before as NSString).substring(with: match.range(at: 1))
        let opens = string.components(separatedBy: "\\begin{\(name)}").count
        let closes = string.components(separatedBy: "\\end{\(name)}").count
        guard opens > closes else { return }
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        super.insertText("\n\(indent)\\end{\(name)}", replacementRange: selection)
        setSelectedRange(selection)
    }

    /// \textbf{…} and the like: an empty selection leaves the caret between the
    /// braces, and selected text stays selected inside them.
    func wrapWithCommand(_ name: String) {
        let selection = selectedRange()
        let opening = "\\\(name){"
        let inner = (string as NSString).substring(with: selection)
        super.insertText(opening + inner + "}", replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + (opening as NSString).length, length: selection.length))
    }

    /// Keeps the indentation of the current line.
    override func insertNewline(_ sender: Any?) {
        keepingCaretHeight { insertIndentedNewline(sender) }
    }

    private func insertIndentedNewline(_ sender: Any?) {
        if !extraCarets.isEmpty {
            let text = string as NSString
            let carets = [selectedRange().location] + extraCarets
            applyCaretEdits(carets.map { caret -> (range: NSRange, text: String) in
                let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
                let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
                let indent = String(before.prefix { $0 == " " || $0 == "\t" })
                return (range: NSRange(location: caret, length: 0), text: "\n" + indent)
            })
            return
        }
        guard isLatexEditing else {
            super.insertNewline(sender)
            return
        }
        let text = string as NSString
        let location = selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        super.insertText("\n" + indent, replacementRange: Self.notFound)
    }

    /// A delete that removes a line break keeps the caret's height, and what's above moves down.
    override func deleteBackward(_ sender: Any?) {
        if !extraCarets.isEmpty {
            deleteAtCarets(forward: false)
            return
        }
        let selection = selectedRange()
        let text = string as NSString
        let removesLineBreak = selection.length > 0
            ? text.substring(with: selection).contains("\n")
            : selection.location > 0 && text.character(at: selection.location - 1) == 10
        if removesLineBreak {
            keepingCaretHeight { deleteBackwardWithPairs(sender) }
        } else {
            deleteBackwardWithPairs(sender)
        }
    }

    /// Deleting the opening half of an empty pair deletes both.
    private func deleteBackwardWithPairs(_ sender: Any?) {
        let selection = selectedRange()
        let text = string as NSString
        if isLatexEditing, selection.length == 0, selection.location > 0, selection.location < text.length {
            let previous = text.character(at: selection.location - 1)
            let next = text.character(at: selection.location)
            let isEscaped = selection.location >= 2 && text.character(at: selection.location - 2) == 92
            if !isEscaped, (previous == 123 && next == 125) || (previous == 36 && next == 36) {
                setSelectedRange(NSRange(location: selection.location - 1, length: 2))
            }
        }
        super.deleteBackward(sender)
    }
}

final class EditorViewController: NSViewController, NSTextViewDelegate {
    var onUserEdit: (() -> Void)?
    var onPasteImage: ((NSPasteboard) -> String?)?
    var onEscape: (() -> Void)?
    var onFocused: (() -> Void)?
    var onSourceClick: ((_ line: Int) -> Void)?
    var citationIndex: CitationIndex?
    var onCitationClicked: ((String) -> Void)?
    var onCitationAccepted: ((String) -> Void)?
    var onIncompleteCitation: ((_ key: String, _ finish: @escaping (String) -> Void) -> Void)?
    var symbols: ProjectSymbols?
    var fileItems: ((ProjectFileKind, String) -> [CompletionItem])?
    let tabBar = EditorTabBar()

    private let completer = CompletionList()
    private var isAcceptingCompletion = false

    private enum CompletionKind: Equatable {
        case citation, reference, environment, command
        case file(ProjectFileKind)
    }
    private struct CompletionContext {
        let kind: CompletionKind
        let range: NSRange
    }

    private static let filePatterns: [(pattern: NSRegularExpression, kind: ProjectFileKind)] = [
        (try! NSRegularExpression(pattern: "\\\\(?:input|include|subfile)\\{([^{}]*)$"), .tex),
        (try! NSRegularExpression(pattern: "\\\\includegraphics\\*?(?:\\[[^\\]\\n]*\\])?\\{([^{}]*)$"), .graphic),
        (try! NSRegularExpression(pattern: "\\\\bibliography\\{([^{}]*)$"), .bibliography),
        (try! NSRegularExpression(pattern: "\\\\addbibresource(?:\\[[^\\]\\n]*\\])?\\{([^{}]*)$"), .bibResource),
    ]
    private static let citePattern = try! NSRegularExpression(
        pattern: "\\\\[a-zA-Z]*[cC]ite[a-zA-Z]*\\*?(?:\\[[^\\]]*\\])*\\{([^{}]*)$")
    private static let refPattern = try! NSRegularExpression(
        pattern: "\\\\(?!href)[a-zA-Z]*[rR]ef\\*?\\{([^{}]*)$")
    private static let environmentPattern = try! NSRegularExpression(
        pattern: "\\\\(?:begin|end)\\{([a-zA-Z*]*)$")
    private static let commandCompletionPattern = try! NSRegularExpression(
        pattern: "(?<!\\\\)\\\\([a-zA-Z@]+)$")

    private(set) var fontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "editorFontSize")
        return stored > 0 ? CGFloat(stored) : 13
    }()
    var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let placeholderStorage = NSTextStorage()
    private var textView: EditorTextView!
    private let scrollView = NSScrollView()
    private var ruler: LineNumberRuler!
    private var previewView: QLPreviewView?
    private var tabBarHeight: NSLayoutConstraint!
    private let messageLabel = NSTextField(labelWithString: L("Elegí un archivo para editarlo", "Choose a file to edit"))
    private var isFocusMode = false
    private var cachedMathRanges: [NSRange]?
    private var bracketRanges: [NSRange] = []

    private(set) var current: TextBuffer?

    private static let commandPattern = try! NSRegularExpression(pattern: "\\\\(?:[a-zA-Z@]+\\*?|.)")
    private static let environmentHighlightPattern = try! NSRegularExpression(pattern: "\\\\(?:begin|end)\\{[^{}\\n]*\\}")
    private static let argumentPattern = try! NSRegularExpression(
        pattern: "\\\\[a-zA-Z@]+\\*?(?:\\[[^\\]\\n]*\\])?\\{([^{}\\n]*)\\}")
    private static let commentPattern = try! NSRegularExpression(pattern: "(?<!\\\\)%.*")
    private static let spellIgnoredPattern = try! NSRegularExpression(pattern:
        "\\\\(?:[a-zA-Z]*cite[a-zA-Z]*|[a-zA-Z]*ref|label|begin|end|input|include|includegraphics|usepackage|documentclass|bibliography|bibliographystyle|addbibresource|url|href|graphicspath)\\*?(?:\\[[^\\]\\n]*\\])*\\{[^{}\\n]*\\}")

    override func loadView() {
        let root = TabDropView()

        placeholderStorage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true

        let text = EditorTextView(frame: .zero, textContainer: container)
        text.imagePasteHandler = { [weak self] pasteboard in
            guard let self, self.isLatexBuffer else { return nil }
            return self.onPasteImage?(pasteboard)
        }
        text.onCaretSettled = { [weak self] in self?.updateCompletion() }
        text.onFocus = { [weak self] in self?.onFocused?() }
        text.onCommandClick = { [weak self] line in self?.onSourceClick?(line) }
        text.onCitationClick = { [weak self] location in
            guard let self, let key = self.citationKey(at: location) else { return false }
            self.onCitationClicked?(key)
            return true
        }
        completer.onAccept = { [weak self] item in self?.acceptCompletion(item) }
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 6, height: 20)
        text.defaultParagraphStyle = TextBuffer.paragraphStyle
        text.drawsBackground = true
        text.delegate = self
        textView = text

        scrollView.documentView = text
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        ruler = LineNumberRuler(textView: text, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resized(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView)

        messageLabel.textColor = .tertiaryLabelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 40)

        root.addSubview(tabBar)
        root.addSubview(scrollView)
        root.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight,
            scrollView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        scrollView.isHidden = true
        view = root
        applyThemeColors()
    }

    // MARK: - Showing content

    func show(_ buffer: TextBuffer) {
        completer.hide()
        rememberPosition()
        removePreview()
        current = buffer
        cachedMathRanges = nil
        bracketRanges = []
        layout.replaceTextStorage(buffer.storage)
        textView.font = font
        textView.typingAttributes = TextBuffer.attributes(font)
        textView.isLatexEditing = isLatexBuffer
        let everything = NSRange(location: 0, length: buffer.storage.length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: everything)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: everything)
        scrollView.isHidden = false
        messageLabel.isHidden = true
        ruler.textChanged()

        let length = buffer.storage.length
        let location = min(buffer.selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(buffer.selection.length, length - location)))
        layout.ensureLayout(for: container)
        textView.sizeToFit()
        scrollView.contentView.scroll(to: buffer.scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        highlightVisible()
        updateBracketHighlight()
    }

    func showPreview(of url: URL) {
        completer.hide()
        rememberPosition()
        current = nil
        removePreview()
        layout.replaceTextStorage(placeholderStorage)
        scrollView.isHidden = true
        messageLabel.isHidden = true
        let created: QLPreviewView? = QLPreviewView(frame: .zero, style: .compact)
        guard let preview = created else { return }
        preview.previewItem = url as NSURL
        preview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        previewView = preview
    }

    func showNothing() {
        completer.hide()
        rememberPosition()
        current = nil
        removePreview()
        layout.replaceTextStorage(placeholderStorage)
        scrollView.isHidden = true
        messageLabel.isHidden = false
    }

    private func removePreview() {
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
    }

    private func rememberPosition() {
        guard let current else { return }
        current.selection = textView.selectedRange()
        current.scrollOrigin = scrollView.contentView.bounds.origin
    }

    func refreshErrorMarks() {
        _ = view
        ruler.needsDisplay = true
    }

    func refreshAfterReload() {
        cachedMathRanges = nil
        ruler.textChanged()
        highlightVisible()
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func go(toLine line: Int, column: Int = 0, length: Int = 0) {
        let text = textView.string as NSString
        var location = 0
        var currentLine = 1
        while currentLine < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            currentLine += 1
        }
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        var target = NSRange(location: lineRange.location, length: 0)
        var indicated = lineRange
        if length > 0, column + length <= lineRange.length {
            target = NSRange(location: lineRange.location + column, length: length)
            indicated = target
        }
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(indicated)
        textView.showFindIndicator(for: indicated)
        focus()
    }

    /// Puts the caret on `word` if it is on that line or very close, since SyncTeX
    /// only knows lines and often reports one near the end of a paragraph.
    /// There is no selection, so that typing right after the jump deletes nothing.
    func go(toLine line: Int, near word: String?) {
        let text = textView.string as NSString
        var starts = [0]
        var index = 0
        for unit in textView.string.utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        func range(ofLine number: Int) -> NSRange? {
            guard number >= 1, number <= starts.count, starts[number - 1] <= text.length else { return nil }
            return text.lineRange(for: NSRange(location: starts[number - 1], length: 0))
        }
        guard let exact = range(ofLine: line) else { return }

        var caret = NSRange(location: exact.location, length: 0)
        var indicated = exact
        if let word, word.count >= 2 {
            for candidate in [line, line - 1, line + 1, line - 2, line + 2] {
                guard let lineRange = range(ofLine: candidate) else { continue }
                let match = text.range(of: word, options: [.diacriticInsensitive, .caseInsensitive], range: lineRange)
                if match.location != NSNotFound {
                    caret = NSRange(location: match.location, length: 0)
                    indicated = match
                    break
                }
            }
        }
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(indicated)
        textView.showFindIndicator(for: indicated)
        focus()
    }

    private var isLatexBuffer: Bool {
        guard let current else { return false }
        return ["tex", "ltx", "tikz", "sty", "cls"].contains(current.url.pathExtension.lowercased())
    }

    // MARK: - Completion

    private func completionContext() -> CompletionContext? {
        guard isLatexBuffer else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let text = textView.string as NSString
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart)) as NSString
        let whole = NSRange(location: 0, length: before.length)

        func partial(_ pattern: NSRegularExpression, afterComma: Bool) -> NSRange? {
            guard let match = pattern.firstMatch(in: before as String, options: [], range: whole) else { return nil }
            let group = match.range(at: 1)
            guard afterComma else { return NSRange(location: lineStart + group.location, length: group.length) }
            let inside = before.substring(with: group) as NSString
            var start = inside.range(of: ",", options: .backwards).location
            start = start == NSNotFound ? 0 : start + 1
            while start < inside.length, inside.character(at: start) == 32 { start += 1 }
            return NSRange(location: lineStart + group.location + start, length: inside.length - start)
        }

        for entry in Self.filePatterns {
            if let range = partial(entry.pattern, afterComma: false) { return CompletionContext(kind: .file(entry.kind), range: range) }
        }
        if let range = partial(Self.citePattern, afterComma: true) { return CompletionContext(kind: .citation, range: range) }
        if let range = partial(Self.refPattern, afterComma: true) { return CompletionContext(kind: .reference, range: range) }
        if let range = partial(Self.environmentPattern, afterComma: false) { return CompletionContext(kind: .environment, range: range) }
        if let range = partial(Self.commandCompletionPattern, afterComma: false) { return CompletionContext(kind: .command, range: range) }
        return nil
    }

    private func completionItems(_ context: CompletionContext, query: String) -> [CompletionItem] {
        switch context.kind {
        case .citation:
            let project = (citationIndex?.matches(for: query) ?? []).map {
                CompletionItem(name: $0.key, insert: $0.key, title: $0.key, detail: $0.summary)
            }
            let library = JevonsLibrary.shared.completions(matching: query, excluding: citationIndex?.entries ?? []).prefix(20).map {
                CompletionItem(name: $0.citeKey, insert: $0.citeKey, title: $0.citeKey,
                               detail: ($0.isComplete ? "Jevons · " : L("Jevons, datos incompletos · ", "Jevons, incomplete data · ")) + $0.summary,
                               needsData: !$0.isComplete)
            }
            return project + library
        case .reference:
            return symbols?.labelItems(matching: query) ?? []
        case .environment:
            return symbols?.environmentItems(matching: query) ?? []
        case .command:
            return symbols?.commandItems(matching: query) ?? []
        case .file(let kind):
            return fileItems?(kind, query) ?? []
        }
    }

    private func updateCompletion() {
        guard !isAcceptingCompletion, !textView.hasExtraCarets, let window = view.window, let context = completionContext() else {
            completer.hide()
            return
        }
        let query = (textView.string as NSString).substring(with: context.range)
        let items = completionItems(context, query: query)
        // Once the word is complete, return must make a new line instead of accepting.
        guard !items.isEmpty, !items.contains(where: { $0.name == query }) else {
            completer.hide()
            return
        }
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        completer.show(items, caret: caret, in: window)
    }

    private func acceptCompletion(_ item: CompletionItem) {
        if item.needsData, let onIncompleteCitation {
            completer.hide()
            onIncompleteCitation(item.insert) { [weak self] key in
                self?.focus()
                self?.acceptCompletion(CompletionItem(name: key, insert: key, title: key, detail: ""))
            }
            return
        }
        guard let context = completionContext() else {
            completer.hide()
            return
        }
        isAcceptingCompletion = true
        let text = textView.string as NSString
        let range = context.range
        let end = NSMaxRange(range)
        let next: unichar = end < text.length ? text.character(at: end) : 0

        switch context.kind {
        case .citation, .reference, .environment, .file:
            if context.kind == .citation { onCitationAccepted?(item.insert) }
            let isBegin = context.kind == .environment && range.location >= 7
                && text.substring(with: NSRange(location: range.location - 7, length: 7)) == "\\begin{"
            if next == 125 { // }
                textView.insertText(item.insert, replacementRange: range)
                textView.setSelectedRange(NSRange(location: range.location + (item.insert as NSString).length + 1, length: 0))
            } else if next == 44 { // ,
                textView.insertText(item.insert, replacementRange: range)
            } else {
                textView.insertText(item.insert + "}", replacementRange: range)
            }
            if isBegin { textView.closeEnvironmentIfNeeded() }
        case .command:
            textView.insertText(item.insert, replacementRange: range)
            let brace = (item.insert as NSString).range(of: "{}")
            if brace.location != NSNotFound {
                textView.setSelectedRange(NSRange(location: range.location + brace.location + 1, length: 0))
            }
        }
        isAcceptingCompletion = false
        completer.hide()
        // A command just completed may leave the caret in an argument that has its own list.
        if context.kind == .command { updateCompletion() }
        if context.kind == .command { updateCompletion() }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if completer.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                completer.moveSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)):
                completer.moveSelection(by: 1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                completer.acceptSelection()
            case #selector(NSResponder.cancelOperation(_:)):
                completer.hide()
            default:
                return false
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), isFocusMode {
            onEscape?()
            return true
        }
        return false
    }

    var canFormatText: Bool {
        isLatexBuffer && view.window?.firstResponder === textView
    }

    func wrapSelection(withCommand name: String) {
        guard canFormatText else { return }
        textView.wrapWithCommand(name)
    }

    /// Replaces the whole file through the text view, so that ⌘Z brings it back.
    func replaceAllText(with text: String) {
        let everything = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: everything, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: everything, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// Where the user is, for the context sent to Claude.
    func caretSnapshot() -> (line: Int, selection: String) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let upToCaret = text.substring(to: min(selection.location, text.length))
        let line = upToCaret.utf16.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        return (line, selection.length > 0 ? text.substring(with: selection) : "")
    }

    /// Applies an accepted change through the text view, so that ⌘Z undoes it. It refuses
    /// unless `old` occurs exactly once, which protects text edited in the meantime.
    func replace(old: String, with new: String) -> Bool {
        let text = textView.string as NSString
        func uniqueRange(of target: String) -> NSRange? {
            guard !target.isEmpty else { return nil }
            let first = text.range(of: target)
            guard first.location != NSNotFound else { return nil }
            let after = NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first))
            return text.range(of: target, options: [], range: after).location == NSNotFound ? first : nil
        }
        var range = uniqueRange(of: old)
        var replacement = new
        if range == nil {
            // Claude may wrap the text in one extra line break at either end.
            let trimmedOld = old.trimmingCharacters(in: .newlines)
            range = uniqueRange(of: trimmedOld)
            replacement = new.trimmingCharacters(in: .newlines)
        }
        guard let found = range, textView.shouldChangeText(in: found, replacementString: replacement) else { return false }
        textView.textStorage?.replaceCharacters(in: found, with: replacement)
        textView.didChangeText()
        let changed = NSRange(location: found.location, length: (replacement as NSString).length)
        textView.setSelectedRange(NSRange(location: found.location, length: 0))
        textView.scrollRangeToVisible(changed)
        if changed.length > 0 { textView.showFindIndicator(for: changed) }
        return true
    }

    func hideCompletion() {
        completer.hide()
    }

    // MARK: - Focus mode

    /// For an editor whose tabs are drawn by the column around it.
    func hideOwnTabBar() {
        _ = view
        tabBarHeight.constant = 0
        tabBar.isHidden = true
    }

    func setFocusMode(_ enabled: Bool) {
        isFocusMode = enabled
        tabBarHeight.constant = enabled ? 0 : 40
        tabBar.isHidden = enabled
        scrollView.rulersVisible = !enabled
        applyFocusInset()
    }

    /// Keeps the text in a centred column of comfortable width.
    private func applyFocusInset() {
        guard let textView else { return }
        if isFocusMode {
            let width = scrollView.bounds.width
            textView.textContainerInset = NSSize(width: max(24, (width - 760) / 2), height: 48)
        } else {
            textView.textContainerInset = NSSize(width: 6, height: 20)
        }
    }

    @objc private func resized(_ notification: Notification) {
        if isFocusMode { applyFocusInset() }
        textView.sizeToFit()
    }

    // MARK: - Spelling

    func setSpelling(language: String?) -> Bool {
        _ = view
        guard let language else {
            textView.isContinuousSpellCheckingEnabled = false
            return true
        }
        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = false
        guard checker.setLanguage(language) else { return false }
        textView.isContinuousSpellCheckingEnabled = true
        textView.checkTextInDocument(nil)
        return true
    }

    /// LaTeX commands, formulas and keys are not words, so they get no red underline.
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any] = [:], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        guard isLatexBuffer else { return results }
        let string = view.string
        let text = string as NSString
        let math = mathRanges()
        return results.filter { result in
            guard result.resultType == .spelling else { return true }
            let word = result.range
            if word.location > 0, text.character(at: word.location - 1) == 92 { return false }
            if math.contains(where: { NSIntersectionRange($0, word).length > 0 }) { return false }
            let line = text.lineRange(for: word)
            for match in Self.spellIgnoredPattern.matches(in: string, options: [], range: line)
            where NSIntersectionRange(match.range, word).length > 0 {
                return false
            }
            return true
        }
    }

    // MARK: - Font and theme

    func changeFontSize(by delta: CGFloat, buffers: [TextBuffer]) {
        fontSize = min(28, max(9, fontSize + delta))
        UserDefaults.standard.set(Double(fontSize), forKey: "editorFontSize")
        for buffer in buffers {
            buffer.storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: buffer.storage.length))
        }
        textView.typingAttributes = TextBuffer.attributes(font)
        ruler.needsDisplay = true
    }

    private func applyThemeColors() {
        let theme = EditorTheme.current
        textView.backgroundColor = theme.background
        textView.caretColor = theme.text
        scrollView.backgroundColor = theme.background
        ruler.needsDisplay = true
    }

    func applyTheme(buffers: [TextBuffer]) {
        applyThemeColors()
        let theme = EditorTheme.current
        for buffer in buffers {
            buffer.storage.addAttribute(.foregroundColor, value: theme.text,
                                        range: NSRange(location: 0, length: buffer.storage.length))
        }
        textView.typingAttributes = TextBuffer.attributes(font)
        highlightVisible()
        updateBracketHighlight()
    }

    // MARK: - Text view delegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        current?.undo
    }

    func textDidChange(_ notification: Notification) {
        current?.dirty = true
        cachedMathRanges = nil
        ruler.textChanged()
        highlightVisible()
        updateCompletion()
        onUserEdit?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Moving the caret out of the context closes the list. Moving inside refreshes it.
        if completer.isVisible { updateCompletion() }
        updateBracketHighlight()
    }

    private static let citationAtCaretPattern = try! NSRegularExpression(
        pattern: "\\\\[a-zA-Z]*[cC]ite[a-zA-Z]*\\*?(?:\\[[^\\]\\n]*\\])*\\{([^{}\\n]*)\\}")

    /// The key at a place in the text: the one under it inside the braces, or the first
    /// one when the place is on the command itself, as on the "citet" of \\citet{key}.
    func citationKey(at location: Int) -> String? {
        guard isLatexBuffer else { return nil }
        let text = textView.string as NSString
        guard location <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        guard lineRange.length < 4000 else { return nil }
        for match in Self.citationAtCaretPattern.matches(in: textView.string, range: lineRange) {
            guard location >= match.range.location, location <= NSMaxRange(match.range) else { continue }
            let group = match.range(at: 1)
            let parts = text.substring(with: group).components(separatedBy: ",")
            var start = group.location
            for part in parts {
                let length = (part as NSString).length
                if location >= start, location <= start + length {
                    let key = part.trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { return key }
                }
                start += length + 1
            }
            return parts.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        return nil
    }

    /// Every key this file cites, each once, in the order they first appear.
    func citedKeysInOrder() -> [(key: String, location: Int, length: Int)] {
        guard isLatexBuffer else { return [] }
        let text = textView.string as NSString
        guard text.length < 2_000_000 else { return [] }
        var seen = Set<String>()
        var found: [(key: String, location: Int, length: Int)] = []
        for match in Self.citationAtCaretPattern.matches(in: textView.string, range: NSRange(location: 0, length: text.length)) {
            let lineStart = text.lineRange(for: NSRange(location: match.range.location, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: match.range.location - lineStart))
            if Self.isCommented(before) { continue }
            let group = match.range(at: 1)
            var start = group.location
            for part in text.substring(with: group).components(separatedBy: ",") {
                let length = (part as NSString).length
                let key = part.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, seen.insert(key).inserted {
                    found.append((key, start, length))
                }
                start += length + 1
            }
        }
        return found
    }

    /// Whether the text before something on its line holds an unescaped %.
    private static func isCommented(_ before: String) -> Bool {
        var previous: Character?
        for character in before {
            if character == "%", previous != "\\" { return true }
            previous = character
        }
        return false
    }

    /// Shows a place in the file without taking the focus away from the row of notes.
    func reveal(location: Int, length: Int) {
        let range = NSRange(location: location, length: length)
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    /// The key under the caret, when it is inside the braces of a citation.
    func citationKeyAtCaret() -> String? {
        guard isLatexBuffer else { return nil }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        guard lineRange.length < 4000 else { return nil }
        for match in Self.citationAtCaretPattern.matches(in: textView.string, range: lineRange) {
            let group = match.range(at: 1)
            guard caret >= group.location, caret <= NSMaxRange(group) else { continue }
            var start = group.location
            for part in text.substring(with: group).components(separatedBy: ",") {
                let length = (part as NSString).length
                if caret <= start + length {
                    let key = part.trimmingCharacters(in: .whitespaces)
                    return key.isEmpty ? nil : key
                }
                start += length + 1
            }
        }
        return nil
    }

    @objc private func scrolled(_ notification: Notification) {
        completer.hide()
        ruler.needsDisplay = true
        highlightVisible()
    }

    // MARK: - Highlighting

    private func mathRanges() -> [NSRange] {
        if let cachedMathRanges { return cachedMathRanges }
        let ranges = LatexScanner.mathRanges(in: textView.string as NSString)
        cachedMathRanges = ranges
        return ranges
    }

    /// Colouring lives in the layout manager, never in the text itself.
    private func highlightVisible() {
        guard !scrollView.isHidden, isLatexBuffer else { return }
        let theme = EditorTheme.current
        let string = textView.string
        let text = string as NSString
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard NSMaxRange(characters) <= text.length else { return }
        let range = text.lineRange(for: characters)

        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        func paint(_ color: NSColor, _ target: NSRange) {
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: target)
        }
        for match in Self.argumentPattern.matches(in: string, options: [], range: range) {
            paint(theme.argument, match.range(at: 1))
        }
        for math in mathRanges() {
            let visible = NSIntersectionRange(math, range)
            if visible.length > 0 { paint(theme.math, visible) }
        }
        for match in Self.commandPattern.matches(in: string, options: [], range: range) {
            paint(theme.command, match.range)
        }
        for match in Self.environmentHighlightPattern.matches(in: string, options: [], range: range) {
            paint(theme.environment, match.range)
        }
        for match in Self.commentPattern.matches(in: string, options: [], range: range) {
            paint(theme.comment, match.range)
        }
    }

    /// Marks the bracket next to the caret and its pair, or in red if it has none.
    private func updateBracketHighlight() {
        let text = textView.string as NSString
        for range in bracketRanges where NSMaxRange(range) <= text.length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketRanges = []
        guard isLatexBuffer else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }

        let opens: [unichar: unichar] = [123: 125, 91: 93, 40: 41]
        let closes: [unichar: unichar] = [125: 123, 93: 91, 41: 40]
        func isBracket(_ position: Int) -> Bool {
            guard position >= 0, position < text.length else { return false }
            let unit = text.character(at: position)
            return opens[unit] != nil || closes[unit] != nil
        }
        let position: Int
        if isBracket(selection.location - 1) {
            position = selection.location - 1
        } else if isBracket(selection.location) {
            position = selection.location
        } else {
            return
        }

        func isEscaped(_ index: Int) -> Bool {
            var count = 0
            var cursor = index - 1
            while cursor >= 0, text.character(at: cursor) == 92 {
                count += 1
                cursor -= 1
            }
            return count % 2 == 1
        }

        let unit = text.character(at: position)
        let escaped = isEscaped(position)
        let forward = opens[unit] != nil
        let partner = forward ? opens[unit]! : closes[unit]!
        var depth = 1
        var cursor = position + (forward ? 1 : -1)
        var steps = 0
        var found: Int?
        while cursor >= 0, cursor < text.length, steps < 100_000 {
            let candidate = text.character(at: cursor)
            if candidate == unit || candidate == partner, isEscaped(cursor) == escaped {
                depth += candidate == unit ? 1 : -1
                if depth == 0 {
                    found = cursor
                    break
                }
            }
            cursor += forward ? 1 : -1
            steps += 1
        }

        let theme = EditorTheme.current
        let own = NSRange(location: position, length: 1)
        if let found {
            let other = NSRange(location: found, length: 1)
            layout.addTemporaryAttribute(.backgroundColor, value: theme.bracket, forCharacterRange: own)
            layout.addTemporaryAttribute(.backgroundColor, value: theme.bracket, forCharacterRange: other)
            bracketRanges = [own, other]
        } else {
            layout.addTemporaryAttribute(.backgroundColor,
                                         value: NSColor.systemRed.withAlphaComponent(0.35), forCharacterRange: own)
            bracketRanges = [own]
        }
    }
}

// MARK: - Compile log

final class LogViewController: NSViewController, NSTextViewDelegate {
    var onSelectIssue: ((CompileIssue) -> Void)?
    var onCopyErrors: (() -> Void)?
    var onCopyFullLog: (() -> Void)?

    private var issues: [CompileIssue] = []
    private var textView: NSTextView!

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L("Log de compilación", "Compilation Log"))
        title.font = .systemFont(ofSize: 11, weight: .medium)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let copyErrors = NSButton(title: L("Copiar errores", "Copy Errors"), target: self, action: #selector(copyErrorsPressed))
        let copyLog = NSButton(title: L("Copiar log completo", "Copy Full Log"), target: self, action: #selector(copyLogPressed))
        for button in [copyErrors, copyLog] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let bar = NSStackView(views: [title, spacer, copyErrors, copyLog])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let root = ThemedBackgroundView { $0.background }
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        textView = scroll.documentView as? NSTextView
        textView.backgroundColor = EditorTheme.current.background
        title.textColor = EditorTheme.current.comment
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemRed,
            .cursor: NSCursor.pointingHand,
        ]
        view = root
    }

    func applyTheme() {
        _ = view
        textView.backgroundColor = EditorTheme.current.background
        view.needsDisplay = true
    }

    @objc private func copyErrorsPressed() { onCopyErrors?() }
    @objc private func copyLogPressed() { onCopyFullLog?() }

    func display(issues newIssues: [CompileIssue], output: String) {
        _ = view // Forces the view to load: the log can receive text while collapsed.
        issues = newIssues
        let result = NSMutableAttributedString()
        let body = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        for (index, issue) in newIssues.enumerated() {
            var label = issue.message
            if let file = issue.file, let line = issue.line {
                label = "\(file):\(line)  \(issue.message)"
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
            ]
            if issue.file != nil { attributes[.link] = "issue:\(index)" }
            result.append(NSAttributedString(string: label, attributes: attributes))
            result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        }
        if !newIssues.isEmpty {
            result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        }
        let tail = output.count > 200_000 ? String(output.suffix(200_000)) : output
        result.append(NSAttributedString(string: tail, attributes: [
            .font: body, .foregroundColor: EditorTheme.current.comment,
        ]))
        textView.textStorage?.setAttributedString(result)
        textView.scrollToBeginningOfDocument(nil)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let value = link as? String, value.hasPrefix("issue:"),
              let index = Int(value.dropFirst(6)), issues.indices.contains(index) else { return false }
        onSelectIssue?(issues[index])
        return true
    }
}
