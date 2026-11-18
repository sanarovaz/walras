import AppKit

extension Notification.Name {
    static let editorThemeChanged = Notification.Name("editorThemeChanged")
}

struct EditorTheme {
    let id: String
    let name: String
    let background: NSColor
    let text: NSColor
    let command: NSColor
    let math: NSColor
    let environment: NSColor
    let argument: NSColor
    let comment: NSColor
    let bracket: NSColor
    let gutterText: NSColor
    let tabBar: NSColor
    let bar: NSColor
    let sidebar: NSColor
    let pdfBackground: NSColor
    let accent: NSColor
    let selection: NSColor
    let separator: NSColor
    let ok: NSColor
    let icon: NSColor

    init(id: String, name: String, background: NSColor, text: NSColor, command: NSColor, math: NSColor,
         environment: NSColor, argument: NSColor, comment: NSColor, bracket: NSColor, gutterText: NSColor,
         tabBar: NSColor, bar: NSColor? = nil, sidebar: NSColor? = nil, pdfBackground: NSColor? = nil,
         accent: NSColor? = nil, selection: NSColor? = nil, separator: NSColor? = nil, ok: NSColor? = nil,
         icon: NSColor? = nil) {
        self.id = id
        self.name = name
        self.background = background
        self.text = text
        self.command = command
        self.math = math
        self.environment = environment
        self.argument = argument
        self.comment = comment
        self.bracket = bracket
        self.gutterText = gutterText
        self.tabBar = tabBar
        self.bar = bar ?? background
        self.sidebar = sidebar ?? tabBar
        self.pdfBackground = pdfBackground ?? tabBar
        self.accent = accent ?? command
        self.selection = selection ?? command.withAlphaComponent(0.16)
        self.separator = separator ?? gutterText.withAlphaComponent(0.35)
        self.ok = ok ?? math
        self.icon = icon ?? comment
    }

    /// One colour for the light appearance and another for the dark one.
    private static func pair(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        let lightColor = hex(light, alpha: lightAlpha)
        let darkColor = hex(dark, alpha: darkAlpha)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    static let all: [EditorTheme] = [
        EditorTheme(id: "walras", name: L("Walras (claro y oscuro)", "Walras (light and dark)"),
                    background: pair(0xFFFFFF, 0x201D18), text: pair(0x1D1D1F, 0xE9E1D3),
                    command: pair(0x0B57C7, 0xDDA562), math: pair(0x7A3E9D, 0xA3BE8F),
                    environment: pair(0x00727A, 0xD08A6B), argument: pair(0x6F5B2E, 0xCFC1A8),
                    comment: pair(0x8E8E93, 0x7A7061),
                    bracket: pair(0x0A66E8, 0xD9A05B, lightAlpha: 0.2, darkAlpha: 0.35),
                    gutterText: pair(0xBDBDC2, 0x5D5548), tabBar: pair(0xFFFFFF, 0x201D18),
                    bar: pair(0xFFFFFF, 0x201D18), sidebar: pair(0xECECEE, 0x1A1713),
                    pdfBackground: pair(0xDCDCDF, 0x14120F), accent: pair(0x0A66E8, 0xE2AC69),
                    selection: pair(0x000000, 0xD9A05B, lightAlpha: 0.09, darkAlpha: 0.17),
                    separator: pair(0xE2E2E4, 0x2F2A23), ok: pair(0x34A853, 0xD9A05B),
                    icon: pair(0x4C4C50, 0xBDB2A0)),
        EditorTheme(id: "oil", name: L("Óleo", "Oil"),
                    background: hex(0x1F1C17), text: hex(0xE8DFCF),
                    command: hex(0xD9A05B), math: hex(0x9DB98B), environment: hex(0xC97F5F),
                    argument: hex(0xCDBEA3), comment: hex(0x7A7061),
                    bracket: hex(0xD9A05B, alpha: 0.35),
                    gutterText: hex(0x6A6254), tabBar: hex(0x171510)),
        EditorTheme(id: "paper", name: L("Papel", "Paper"),
                    background: hex(0xF7F2E7), text: hex(0x3A342A),
                    command: hex(0x8A4B14), math: hex(0x3F6B3A), environment: hex(0x8C2F39),
                    argument: hex(0x5D5340), comment: hex(0x978C78),
                    bracket: hex(0xD9A05B, alpha: 0.4),
                    gutterText: hex(0xB5AA95), tabBar: hex(0xEDE6D6)),
        EditorTheme(id: "nord", name: "Nord",
                    background: hex(0x2E3440), text: hex(0xD8DEE9),
                    command: hex(0x81A1C1), math: hex(0xA3BE8C), environment: hex(0xB48EAD),
                    argument: hex(0xE5E9F0), comment: hex(0x6C7A92),
                    bracket: hex(0x88C0D0, alpha: 0.35),
                    gutterText: hex(0x566176), tabBar: hex(0x272C36)),
        EditorTheme(id: "solarized-light", name: L("Solarized claro", "Solarized Light"),
                    background: hex(0xFDF6E3), text: hex(0x586E75),
                    command: hex(0x268BD2), math: hex(0x859900), environment: hex(0xD33682),
                    argument: hex(0xB58900), comment: hex(0x93A1A1),
                    bracket: hex(0xB58900, alpha: 0.3),
                    gutterText: hex(0xB4BDB6), tabBar: hex(0xEEE8D5)),
        EditorTheme(id: "solarized-dark", name: L("Solarized oscuro", "Solarized Dark"),
                    background: hex(0x002B36), text: hex(0x93A1A1),
                    command: hex(0x268BD2), math: hex(0x859900), environment: hex(0xD33682),
                    argument: hex(0xB58900), comment: hex(0x586E75),
                    bracket: hex(0xB58900, alpha: 0.35),
                    gutterText: hex(0x476A73), tabBar: hex(0x00212B)),
    ]

    static var current: EditorTheme {
        get {
            let id = UserDefaults.standard.string(forKey: "editorThemeV2")
            return all.first { $0.id == id } ?? all[0]
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "editorThemeV2")
            NotificationCenter.default.post(name: .editorThemeChanged, object: nil)
        }
    }
}

enum AppearanceMode: Int, CaseIterable {
    case automatic, light, dark

    var title: String {
        switch self {
        case .automatic: return L("Igual que el sistema", "Match System")
        case .light: return L("Clara", "Light")
        case .dark: return L("Oscura", "Dark")
        }
    }

    static var current: AppearanceMode {
        get { AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: "appearanceMode")) ?? .automatic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearanceMode")
            apply()
        }
    }

    static func apply() {
        switch current {
        case .automatic: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum LatexScanner {
    private static let mathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*",
        "flalign", "flalign*", "alignat", "alignat*", "eqnarray", "eqnarray*", "displaymath", "math",
    ]

    private enum Mode: Equatable {
        case text, dollar, doubleDollar, bracket, parenthesis, environment(String)
    }

    /// Whole-document scan, because display math spans lines. Comments are skipped,
    /// and an unclosed $ ends at the next blank line so it cannot colour the whole file.
    static func mathRanges(in text: NSString) -> [NSRange] {
        let length = text.length
        guard length > 0, length < 2_000_000 else { return [] }
        var units = [unichar](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))

        var ranges: [NSRange] = []
        var mode = Mode.text
        var start = 0
        var index = 0

        func environmentName(at position: Int, prefix: [unichar]) -> (name: String, end: Int)? {
            let open = position + prefix.count
            guard open < length, Array(units[position..<open]) == prefix else { return nil }
            var end = open
            while end < length, units[end] != 125, units[end] != 10 { end += 1 }
            guard end < length, units[end] == 125 else { return nil }
            return (String(decoding: units[open..<end], as: UTF16.self), end + 1)
        }
        let beginPrefix = Array("\\begin{".utf16)
        let endPrefix = Array("\\end{".utf16)

        while index < length {
            let unit = units[index]
            let next: unichar = index + 1 < length ? units[index + 1] : 0
            switch unit {
            case 37: // %
                while index < length, units[index] != 10 { index += 1 }
                continue
            case 10:
                if mode == .dollar, next == 10 { mode = .text }
                index += 1
            case 36: // $
                if mode == .text {
                    start = index
                    mode = next == 36 ? .doubleDollar : .dollar
                    index += next == 36 ? 2 : 1
                } else if mode == .dollar {
                    ranges.append(NSRange(location: start, length: index + 1 - start))
                    mode = .text
                    index += 1
                } else if mode == .doubleDollar, next == 36 {
                    ranges.append(NSRange(location: start, length: index + 2 - start))
                    mode = .text
                    index += 2
                } else {
                    index += 1
                }
            case 92: // backslash
                if mode == .text, next == 91 || next == 40 {
                    start = index
                    mode = next == 91 ? .bracket : .parenthesis
                    index += 2
                } else if (mode == .bracket && next == 93) || (mode == .parenthesis && next == 41) {
                    ranges.append(NSRange(location: start, length: index + 2 - start))
                    mode = .text
                    index += 2
                } else if mode == .text, next == 98, let found = environmentName(at: index, prefix: beginPrefix),
                          mathEnvironments.contains(found.name) {
                    start = index
                    mode = .environment(found.name)
                    index = found.end
                } else if case .environment(let name) = mode, next == 101,
                          let found = environmentName(at: index, prefix: endPrefix), found.name == name {
                    ranges.append(NSRange(location: start, length: found.end - start))
                    mode = .text
                    index = found.end
                } else {
                    index += 2
                }
            default:
                index += 1
            }
        }
        if mode != .text, mode != .dollar {
            ranges.append(NSRange(location: start, length: length - start))
        }
        return ranges
    }
}
