import AppKit
import SeerCore

/// Repos and appearance settings; changes apply live, Save writes them to the config file. Esc closes.
final class SettingsWindow: NSPanel, NSTextFieldDelegate {
    private let fontPopup = NSPopUpButton()
    private struct Binding {
        let get: () -> CGFloat
        let set: (CGFloat) -> Void
    }
    private var steppers: [(NSStepper, NSTextField, Binding)] = []
    private let reposText = NSTextView()
    private let reposStatus = NSTextField(labelWithString: "")
    private let copilotModel = NSTextField()
    private let account = NSPopUpButton()
    private let terminal = NSPopUpButton()
    private let sourceDir = NSTextField()
    private static let activeAccount = "gh active account"
    /// Called with the new config after the repo list is saved.
    var onReposSaved: ((Config) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Seer Settings"
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = Theme.panel
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let families = NSFontManager.shared.availableFontFamilies.filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
        fontPopup.addItem(withTitle: "System Monospace")
        fontPopup.addItems(withTitles: families)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)

        let rows: [[NSView]] = [
            [label("Font"), fontPopup],
            [label("Diff font size"), stepper(Binding(get: { Settings.diffFontSize }, set: { Settings.diffFontSize = $0 }), min: 8, max: 32, step: 1)],
            [label("UI font size"), stepper(Binding(get: { Settings.uiFontSize }, set: { Settings.uiFontSize = $0 }), min: 8, max: 32, step: 1)],
            [label("Line spacing"), stepper(Binding(get: { Settings.lineSpacing }, set: { Settings.lineSpacing = $0 }), min: 0, max: 20, step: 1)],
            [label("Copilot model"), copilotModel],
            [label("GitHub account"), account],
            [label("Terminal"), terminal],
            [label("Source directory"), sourceDir],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetAll))
        let hint = NSTextField(labelWithString: "Changes apply immediately · Save settings keeps them · Esc closes")
        hint.textColor = Theme.dim
        hint.font = .systemFont(ofSize: 11)
        copilotModel.font = Theme.uiFont
        copilotModel.textColor = Theme.text
        copilotModel.backgroundColor = Theme.raised
        copilotModel.drawsBackground = true
        copilotModel.isBordered = false
        copilotModel.focusRingType = .none
        copilotModel.placeholderString = "auto"
        copilotModel.delegate = self
        copilotModel.widthAnchor.constraint(equalToConstant: 220).isActive = true

        account.addItem(withTitle: Self.activeAccount)
        account.widthAnchor.constraint(equalToConstant: 220).isActive = true
        account.target = self
        account.action = #selector(accountChanged)
        Task.detached {
            let logins = GitHub.ghAccounts()
            await MainActor.run { [weak self] in self?.setAccounts(logins) }
        }

        terminal.addItems(withTitles: Terminal.allCases.map(\.rawValue))
        terminal.target = self
        terminal.action = #selector(terminalChanged)
        sourceDir.font = Theme.uiFont
        sourceDir.textColor = Theme.text
        sourceDir.backgroundColor = Theme.raised
        sourceDir.drawsBackground = true
        sourceDir.isBordered = false
        sourceDir.focusRingType = .none
        sourceDir.placeholderString = "~/source"
        sourceDir.delegate = self
        sourceDir.widthAnchor.constraint(equalToConstant: 220).isActive = true

        reposText.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        reposText.textColor = Theme.text
        reposText.backgroundColor = Theme.bg
        reposText.insertionPointColor = Theme.text
        reposText.isRichText = false
        reposText.isAutomaticQuoteSubstitutionEnabled = false
        reposText.isAutomaticDashSubstitutionEnabled = false
        reposText.textContainerInset = NSSize(width: 6, height: 6)
        reposText.isVerticallyResizable = true
        reposText.autoresizingMask = [.width]
        reposText.textContainer?.widthTracksTextView = true
        let reposScroll = NSScrollView()
        reposScroll.documentView = reposText
        reposScroll.hasVerticalScroller = true
        reposScroll.wantsLayer = true
        reposScroll.layer?.cornerRadius = 6
        reposScroll.layer?.borderColor = Theme.border.cgColor
        reposScroll.layer?.borderWidth = 1
        reposScroll.translatesAutoresizingMaskIntoConstraints = false
        reposScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        reposScroll.widthAnchor.constraint(equalToConstant: 424).isActive = true
        let reposTitle = NSTextField(labelWithString: "Repositories (one owner/name per line)")
        reposTitle.font = .boldSystemFont(ofSize: 13)
        reposTitle.textColor = Theme.text
        let reposPath = NSTextField(labelWithString: Config.path())
        reposPath.font = .systemFont(ofSize: 11)
        reposPath.textColor = Theme.dim
        reposPath.lineBreakMode = .byTruncatingMiddle
        let save = NSButton(title: "Save settings", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        reposStatus.font = .systemFont(ofSize: 11)
        reposStatus.lineBreakMode = .byTruncatingTail
        reposStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reposText.string = Config.rawRepos().joined(separator: "\n")

        let line = FillView(Theme.border)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: 424).isActive = true

        let stack = NSStackView(views: [reposTitle, reposPath, reposScroll, line, grid,
                                        NSStackView(views: [save, reset, reposStatus]), hint])
        stack.setCustomSpacing(4, after: reposTitle)
        stack.setCustomSpacing(8, after: reposPath)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.appearance = NSAppearance(named: .darkAqua)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = Theme.panel.cgColor
        contentView = stack
        sync()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = Theme.text
        return l
    }

    private func stepper(_ key: Binding, min: Double, max: Double, step: Double) -> NSView {
        let s = NSStepper()
        s.minValue = min
        s.maxValue = max
        s.increment = step
        s.valueWraps = false
        s.target = self
        s.action = #selector(stepped(_:))
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        value.textColor = Theme.text
        value.widthAnchor.constraint(equalToConstant: 36).isActive = true
        steppers.append((s, value, key))
        return NSStackView(views: [value, s])
    }

    private func sync() {
        let name = Settings.fontName
        if name.isEmpty { fontPopup.selectItem(at: 0) } else { fontPopup.selectItem(withTitle: name) }
        for (s, v, key) in steppers {
            s.doubleValue = Double(key.get())
            v.stringValue = "\(Int(key.get()))"
        }
        copilotModel.stringValue = Settings.copilotModel
        selectAccount()
        terminal.selectItem(withTitle: Settings.terminal.rawValue)
        sourceDir.stringValue = Settings.sourceDir
    }

    private func setAccounts(_ logins: [String]) {
        account.removeAllItems()
        account.addItem(withTitle: Self.activeAccount)
        account.addItems(withTitles: logins)
        selectAccount()
    }

    /// A saved login gh no longer lists stays selectable so Save doesn't silently drop it.
    private func selectAccount() {
        let saved = Settings.account
        if saved.isEmpty { return account.selectItem(at: 0) }
        if account.item(withTitle: saved) == nil { account.addItem(withTitle: saved) }
        account.selectItem(withTitle: saved)
    }

    @objc private func terminalChanged() {
        Settings.terminal = Terminal(rawValue: terminal.titleOfSelectedItem ?? "") ?? .ghostty
    }

    @objc private func accountChanged() {
        Settings.account = account.indexOfSelectedItem == 0 ? "" : account.titleOfSelectedItem ?? ""
    }

    @objc private func fontChanged() {
        Settings.fontName = fontPopup.indexOfSelectedItem == 0 ? "" : fontPopup.titleOfSelectedItem ?? ""
    }

    @objc private func stepped(_ sender: NSStepper) {
        guard let (_, _, key) = steppers.first(where: { $0.0 === sender }) else { return }
        key.set(CGFloat(sender.doubleValue))
        sync()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let field = notification.object as AnyObject?
        if field === copilotModel { Settings.copilotModel = copilotModel.stringValue }
        else if field === sourceDir { Settings.sourceDir = sourceDir.stringValue }
        else { return }
        sync()
    }

    @objc private func saveSettings() {
        Settings.copilotModel = copilotModel.stringValue
        Settings.sourceDir = sourceDir.stringValue
        sync()
        let entries = reposText.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            let config = try Config.save(entries, settings: Settings.snapshot)
            reposStatus.stringValue = "Settings saved ✓"
            reposStatus.textColor = Theme.green
            onReposSaved?(config)
        } catch {
            reposStatus.stringValue = "\(error)"
            reposStatus.textColor = Theme.red
        }
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset settings to defaults?"
        alert.informativeText = "Font, sizes, spacing and Copilot model, GitHub account, terminal and source directory go back to defaults. Repositories are kept. Press Save settings to write the defaults to the config file."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: self) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            Settings.reset()
            sync()
        }
    }

    override func cancelOperation(_: Any?) { close() }
}
