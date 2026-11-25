import AppKit
import SeerCore

/// User-adjustable settings, loaded from and saved to the config file.
enum Settings {
    static let changed = Notification.Name("SeerSettingsChanged")
    private static var s = AppSettings()

    static var snapshot: AppSettings { s }

    static func load() { s = Config.loadSettings() }

    static var fontName: String {
        get { s.fontName }
        set { s.fontName = newValue; apply() }
    }
    static var diffFontSize: CGFloat {
        get { min(max(s.diffFontSize, 8), 32) }
        set { s.diffFontSize = Double(newValue); apply() }
    }
    static var uiFontSize: CGFloat {
        get { min(max(s.uiFontSize, 8), 32) }
        set { s.uiFontSize = Double(newValue); apply() }
    }
    static var lineSpacing: CGFloat {
        get { min(max(s.lineSpacing, 0), 20) }
        set { s.lineSpacing = Double(newValue); apply() }
    }
    static var copilotModel: String {
        get { s.copilotModel.isEmpty ? "auto" : s.copilotModel }
        set { s.copilotModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static var terminal: Terminal {
        get { Terminal(rawValue: s.terminal) ?? .ghostty }
        set { s.terminal = newValue.rawValue }
    }
    static var sourceDir: String {
        get { s.sourceDir.isEmpty ? "~/source" : s.sourceDir }
        set { s.sourceDir = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static var account: String {
        get { s.account }
        set { s.account = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func reset() {
        s = AppSettings()
        apply()
    }

    private static func apply() {
        Theme.reload()
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// GitHub dark (Primer) colors; fonts and row heights follow Settings.
enum Theme {
    private(set) static var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private(set) static var bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    private(set) static var rowHeight: CGFloat = 19
    private(set) static var charWidth: CGFloat = 8
    private(set) static var uiFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private(set) static var uiBold = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    private(set) static var uiRowHeight: CGFloat = 22
    private(set) static var paragraph = NSParagraphStyle()
    /// Like `paragraph` but wrapping, with every visual line exactly `rowHeight` apart.
    private(set) static var wrapParagraph = NSParagraphStyle()

    static func monoFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let name = Settings.fontName
        if !name.isEmpty, let f = NSFont(name: name, size: size) {
            return bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    static func reload() {
        font = monoFont(Settings.diffFontSize)
        bold = monoFont(Settings.diffFontSize, bold: true)
        uiFont = monoFont(Settings.uiFontSize)
        uiBold = monoFont(Settings.uiFontSize, bold: true)
        func height(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }
        rowHeight = height(font) + Settings.lineSpacing
        uiRowHeight = height(uiFont) + Settings.lineSpacing + 4
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let p = NSMutableParagraphStyle()
        p.tabStops = []
        p.defaultTabInterval = charWidth * 4
        p.lineBreakMode = .byClipping
        paragraph = p
        let w = p.mutableCopy() as! NSMutableParagraphStyle
        w.lineBreakMode = .byCharWrapping
        w.minimumLineHeight = height(font)
        w.maximumLineHeight = height(font)
        w.lineSpacing = Settings.lineSpacing
        wrapParagraph = w
    }

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static let bg = hex(0x0D1117)
    static let panel = hex(0x161B22)
    static let raised = hex(0x21262D)
    static let border = hex(0x30363D)
    static let text = hex(0xE6EDF3)
    static let dim = hex(0x7D8590)
    static let accent = hex(0x2F81F7)
    static let cursor = hex(0x388BFD, 0.22)
    static let cursorUnfocused = hex(0x6E7681, 0.16)
    static let visual = hex(0x388BFD, 0.35)
    static let addBg = hex(0x2EA043, 0.15)
    static let delBg = hex(0xF85149, 0.15)
    static let addGutter = hex(0x3FB950, 0.3)
    static let delGutter = hex(0xF85149, 0.3)
    static let hunkBg = hex(0x388BFD, 0.1)
    static let hunkFg = hex(0x8DA2BE)
    static let commentBg = hex(0xBB8009, 0.1)
    static let green = hex(0x3FB950)
    static let red = hex(0xF85149)
    static let yellow = hex(0xD29922)
    static let orange = hex(0xDB6D28)
    static let purple = hex(0xA371F7)

    static let groups: [String: NSColor] = [
        "keyword": hex(0xFF7B72), "string": hex(0xA5D6FF), "comment": hex(0x8B949E),
        "type": hex(0xFFA657), "function": hex(0xD2A8FF), "number": hex(0x79C0FF),
        "property": hex(0x79C0FF), "operator": hex(0xFF7B72), "punctuation": text,
        "none": text,
    ]

    static func attrs(_ color: NSColor = text, bold: Bool = false, ui: Bool = false) -> [NSAttributedString.Key: Any] {
        let f = ui ? (bold ? uiBold : uiFont) : (bold ? Theme.bold : font)
        return [.font: f, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// GitHub-style five-square diffstat.
    static func diffstat(_ adds: Int, _ dels: Int, ui: Bool = true) -> NSAttributedString {
        let total = adds + dels
        let g = total == 0 ? 0 : Int((Double(adds) / Double(total) * 5).rounded())
        let r = total == 0 ? 0 : min(5 - g, Int((Double(dels) / Double(total) * 5).rounded()))
        return NSMutableAttributedString()
            .add(String(repeating: "■", count: g), green, ui: ui)
            .add(String(repeating: "■", count: r), red, ui: ui)
            .add(String(repeating: "■", count: 5 - g - r), raised, ui: ui)
    }
}

extension NSMutableAttributedString {
    @discardableResult
    func add(_ s: String, _ color: NSColor = Theme.text, bold: Bool = false, ui: Bool = false) -> Self {
        append(NSAttributedString(string: s, attributes: Theme.attrs(color, bold: bold, ui: ui)))
        return self
    }

    @discardableResult
    func ui(_ s: String, _ color: NSColor = Theme.text, bold: Bool = false) -> Self {
        add(s, color, bold: bold, ui: true)
    }

    /// Text on a colored background, used as a badge.
    @discardableResult
    func pill(_ s: String, _ color: NSColor) -> Self {
        var a = Theme.attrs(color, bold: true, ui: true)
        a[.backgroundColor] = color.withAlphaComponent(0.18)
        a[.font] = Theme.monoFont(max(Settings.uiFontSize - 2, 8), bold: true)
        a[.baselineOffset] = 1
        append(NSAttributedString(string: " \(s) ", attributes: a))
        return self
    }
}

/// NSSplitView with a 1px GitHub border divider.
final class BorderSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.border }
    override var dividerThickness: CGFloat { 1 }
}

/// Plain view with a fill color and optional 1px borders.
final class FillView: NSView {
    var color: NSColor
    var topBorder = false

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        color.setFill()
        bounds.fill()
        Theme.border.setFill()
        if topBorder { NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill() }
    }
}

/// Title bar above a pane; the accent line shows which pane has focus.
final class PaneHeader: NSView {
    var title = NSAttributedString() { didSet { needsDisplay = true } }
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Theme.uiRowHeight + 6) }

    override func draw(_ dirty: NSRect) {
        Theme.panel.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        if focused {
            Theme.accent.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
        let h = title.size().height
        title.draw(with: NSRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 20, height: h + 2),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

func key(from e: NSEvent) -> Key? {
    if e.keyCode == 53 { return .escape }
    if e.keyCode == 36 || e.keyCode == 76 { return .enter }
    let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods.contains(.command) || mods.contains(.option) { return nil }
    if mods.contains(.control) { return e.charactersIgnoringModifiers?.first.map(Key.ctrl) }
    return e.characters?.first.map(Key.char)
}
