import AppKit
import SeerCore

final class MainWindow: NSWindow {
    /// ctrl+h/j/k/l pane switching; return true if handled.
    var onFocusKey: ((Character) -> Bool)?
    var onResponderChange: (() -> Void)?

    override func makeFirstResponder(_ r: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(r)
        onResponderChange?()
        return ok
    }

    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, !(firstResponder is NSTextView),
           e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           let c = e.charactersIgnoringModifiers?.first, "hjkl".contains(c), onFocusKey?(c) == true {
            return
        }
        super.sendEvent(e)
    }
}

private struct Loaded: Sendable {
    let diff: Diff
    let detail: PRDetail
}

/// In-flight or finished loads for one PR; highlighting runs after the diff is shown.
private struct Entry {
    let load: Task<Loaded, Error>
    let highlight: Task<[Int: [HLSpan]], Never>
}

private func key(_ pr: PRSummary) -> String { "\(pr.repo.full)#\(pr.number)" }

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
    private let container = NSView()
    private let status = NSTextField(labelWithString: "")
    private let mode = NSTextField(labelWithString: "")
    private let search = NSTextField()
    private var lastList: PRList?
    private let prList = ListView()
    private let checks = ListView()
    private let files = ListView()
    private let diffView = DiffView()
    private let help = HelpView()
    private let submitModal = ChoiceModal(.submit)
    private let mergeModal = ChoiceModal(.merge)
    private let closeModal = ChoiceModal(.close)
    private var checksOffset = 0
    private let aiDrawer = AIDrawerView()
    private var copilotRunner: CopilotRunner?
    private var copilotTask: Task<Void, Never>?
    private let outdatedBanner = FillView(Theme.yellow)
    private let outdatedLabel = NSTextField(labelWithString: "PR updated on GitHub — press Shift+R to reload")
    private lazy var prScreen = makePRScreen()
    private lazy var listScreen = withHeader(listHeader, prList.scrollView)
    private lazy var settingsWindow = SettingsWindow()
    private let listHeader = PaneHeader()
    private let prHeader = PaneHeader()
    private let checksHeader = PaneHeader()
    private let filesHeader = PaneHeader()
    private let statusBar = FillView(Theme.panel)
    private var busyText: String?
    private var busyTimer: Timer?
    private var prMonitor: Timer?
    private var prMonitorBusy = false
    private var busyTick = 0
    private var busyID = 0
    private lazy var statusHeight = statusBar.heightAnchor.constraint(equalToConstant: Theme.uiRowHeight + 6)

    private var gh: GitHub?
    private var config: Config?
    private var listItems: [PRSummary?] = []
    private var entries: [String: Entry] = [:]
    private var lru: [String] = []
    private var prefetch: DispatchWorkItem?

    private var current: PRSummary?
    /// The PR on screen; replaced on every load, so async work checks `session === s` before touching the UI.
    private var session: ReviewSession?
    private var detail: PRDetail? { session?.detail }
    private var lastSidebar: ListView?
    private var onPRScreen = false
    private weak var aiSource: NSView?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Settings.load()
        Theme.reload()
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        setupMenu()
        setupWindow()
        showList()
        NSApp.activate()

        settingsWindow.onReposSaved = { [weak self] c in self?.start(c) }
        do {
            start(try Config.load())
        } catch {
            showError("\(error)\n\nFix the repo list in Settings (press , or ⌘,).")
        }
    }

    private func start(_ c: Config) {
        config = c
        guard !c.repos.isEmpty else {
            listHeader.title = NSMutableAttributedString().ui("Pull requests", Theme.text, bold: true)
            prList.rows = ["", "  No repositories configured yet.", "", "  Press , (or ⌘,) to open Settings and add owner/name repos."].map {
                ListRow(text: NSMutableAttributedString().ui($0, Theme.dim), selectable: false)
            }
            return setStatus("No repos configured")
        }
        if gh == nil {
            do {
                gh = GitHub(token: try GitHub.loadToken())
            } catch {
                return showError("\(error)")
            }
        }
        if let cached = lastList ?? PRCache.load() { render(cached) }
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    // MARK: Layout

    private func setupMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appItem.submenu?.items.last?.target = self
        appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(withTitle: "Quit Seer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupWindow() {
        window.title = "Seer"
        window.backgroundColor = Theme.bg
        window.center()
        window.setFrameAutosaveName("SeerMain")
        window.onFocusKey = { [weak self] c in self?.focusKey(c) ?? false }

        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.wantsLayer = true
        mode.layer?.cornerRadius = 4
        window.onResponderChange = { [weak self] in self?.updateMode() }
        mode.textColor = Theme.bg
        outdatedLabel.font = Theme.uiBold
        outdatedLabel.textColor = Theme.bg
        outdatedLabel.alignment = .center
        outdatedLabel.translatesAutoresizingMaskIntoConstraints = false
        outdatedBanner.translatesAutoresizingMaskIntoConstraints = false
        search.textColor = Theme.text
        search.backgroundColor = Theme.raised
        search.drawsBackground = true
        search.isBordered = false
        search.focusRingType = .none
        search.placeholderAttributedString = NSAttributedString(string: "/ filter repo or title",
                                                                attributes: [.foregroundColor: Theme.dim])
        search.delegate = self
        search.isHidden = true
        search.widthAnchor.constraint(equalToConstant: 320).isActive = true
        applyStatusFonts()
        let bar = NSStackView(views: [mode, search, status])
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        statusBar.topBorder = true
        let root = NSView()
        for v in [container, statusBar, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.topAnchor.constraint(equalTo: statusBar.topAnchor, constant: 1),
            bar.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor),
            statusHeight,
        ])
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = root

        prList.onEnter = { [weak self] i in self?.listItems[i].map { self?.open($0) } }
        prList.onCursor = { [weak self] i in self?.schedulePrefetch(i) }
        prList.onCommand = { [weak self] cmd in
            guard let self else { return false }
            switch cmd {
            case .refresh: refresh()
            case .other("R"):
                refresh(clearList: true)
            case .other("/"): beginSearch()
            case .escape where !search.stringValue.isEmpty: endSearch(clear: true)
            case .open: if let pr = listItems[safe: prList.cursor] ?? nil { openURL(pr.url) }
            case .other("l"), .other("h"):
                let items = listItems
                let starts = items.indices.filter { items[$0] != nil && (items[safe: $0 - 1] ?? nil) == nil }
                let at = prList.cursor
                let cur = starts.last { $0 <= at } ?? 0
                let target = cmd == .other("l") ? starts.first { $0 > cur } : starts.last { $0 < cur }
                if let target { prList.setCursor(target) } else { return false }
            case .checkout: if let pr = listItems[safe: prList.cursor] ?? nil { copyCheckout(pr) }
            case .other(","): openSettings()
            case .other("?"): showHelp()
            default: return false
            }
            return true
        }

        checks.onCommand = { [weak self] cmd in
            guard let self else { return false }
            if cmd == .open, let d = detail {
                let i = checks.cursor - checksOffset
                openURL(d.checks.indices.contains(i) ? d.checks[i].url ?? d.url : d.url)
                return true
            }
            return prCommand(cmd)
        }
        files.onEnter = { [weak self] i in
            guard let self else { return }
            diffView.scrollToFile(i, firstLine: true)
            window.makeFirstResponder(diffView)
        }
        files.onCommand = { [weak self] cmd in self?.prCommand(cmd) ?? false }
        diffView.onCommand = { [weak self] cmd in self?.prCommand(cmd) ?? false }
        diffView.onMode = { [weak self] m in self?.setMode(m) }
        diffView.onStatus = { [weak self] in self?.setStatus($0) }
        checks.onFocus = { [weak self] f in self?.checksHeader.focused = f }
        files.onFocus = { [weak self] f in self?.filesHeader.focused = f }
        diffView.onFocus = { [weak self] f in self?.prHeader.focused = f }
        prList.onFocus = { [weak self] f in self?.listHeader.focused = f }
        diffView.onComment = { [weak self] t in self?.beginComment(t) }
        diffView.onReply = { [weak self] t in self?.beginReply(t) }
        diffView.onEdit = { [weak self] t, c in self?.beginEdit(t, c) }
        help.onClose = { [weak self] in self?.closeHelp() }
        mergeModal.onClose = { [weak self] in self?.closeMerge() }
        mergeModal.onChoose = { [weak self] method, _, text in
            self?.closeMerge()
            self?.merge(method, text)
        }
        closeModal.onClose = { [weak self] in self?.closeCloseModal() }
        closeModal.onChoose = { [weak self] _, _, text in
            self?.closeCloseModal()
            self?.close(text)
        }
        submitModal.onClose = { [weak self] in self?.closeSubmit() }
        submitModal.onChoose = { [weak self] event, name, body in
            self?.closeSubmit()
            self?.submit(event, name, body)
        }
        aiDrawer.onModeChange = { [weak self] in self?.updateMode() }
        aiDrawer.onStatus = { [weak self] in self?.setStatus($0) }
        aiDrawer.onSubmit = { [weak self] prompt in self?.askCopilot(prompt) }
        aiDrawer.onClose = { [weak self] in self?.closeAIDrawer() }
        aiDrawer.onCancel = { [weak self] in if self?.copilotTask != nil { self?.cancelCopilot() } else { self?.closeAIDrawer() } }
        window.makeKeyAndOrderFront(nil)
    }

    private func makePRScreen() -> NSView {
        let sidebar = BorderSplitView()
        sidebar.isVertical = false
        sidebar.addArrangedSubview(withHeader(checksHeader, checks.scrollView))
        sidebar.addArrangedSubview(withHeader(filesHeader, files.scrollView))

        let right = NSStackView(views: [diffView.scrollView])
        right.orientation = .vertical
        right.distribution = .fill
        right.spacing = 0
        diffView.scrollView.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let split = BorderSplitView()
        split.isVertical = true
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(withHeader(prHeader, right))
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        DispatchQueue.main.async {
            split.setPosition(360, ofDividerAt: 0)
            sidebar.setPosition(sidebar.bounds.height * 0.35, ofDividerAt: 0)
        }
        return split
    }

    /// `header` pinned above `content`.
    private func withHeader(_ header: NSView, _ content: NSView) -> NSView {
        let v = NSView()
        for c in [header, content] {
            c.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(c)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    @objc private func openSettings() {
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func applyStatusFonts() {
        for l in [status, mode, search] { l.font = Theme.uiFont }
        statusHeight.constant = Theme.uiRowHeight + 6
    }

    private func applySettings() {
        applyStatusFonts()
        diffView.applyEditorFont()
        for h in [listHeader, prHeader, checksHeader, filesHeader] { h.invalidateIntrinsicContentSize() }
        if let lastList { render(lastList) } else { prList.reload() }
        if onPRScreen, let pr = current {
            renderPRHeader(pr)
            renderChecks()
            renderFiles()
            diffView.reload()
        }
    }

    private var diffMode = ""

    private func setMode(_ m: String) {
        diffMode = m
        updateMode()
    }

    /// Global mode: INSERT whenever a text field/view has focus, else the diff's NORMAL / VISUAL.
    private func updateMode() {
        let insert = window.firstResponder is NSTextView
        let inAI = window.firstResponder === aiDrawer
        let visual = inAI ? aiDrawer.isVisual : diffMode.hasPrefix("-- VISUAL")
        let pending = inAI ? "" : diffMode.replacingOccurrences(of: "-- VISUAL LINE --", with: "").trimmingCharacters(in: .whitespaces)
        let name = insert ? "INSERT" : visual ? "VISUAL" : "NORMAL"
        mode.stringValue = " \(name)\(pending.isEmpty || insert ? "" : " " + pending) "
        mode.layer?.backgroundColor = (insert ? Theme.green : visual ? Theme.purple : Theme.accent).cgColor
    }

    private func show(_ v: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.layoutSubtreeIfNeeded()
    }

    private func showHelp() {
        guard help.superview == nil else { return }
        let previous = window.firstResponder as? NSView
        help.onClose = { [weak self, weak previous] in
            self?.closeHelp(previous: previous)
        }
        help.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(help)
        NSLayoutConstraint.activate([
            help.topAnchor.constraint(equalTo: container.topAnchor),
            help.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            help.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.makeFirstResponder(help)
    }

    private func closeHelp(previous: NSView? = nil) {
        guard help.superview != nil else { return }
        help.removeFromSuperview()
        window.makeFirstResponder(previous ?? (onPRScreen ? diffView : prList))
    }

    private func aiContext() -> (label: String, text: String) {
        aiSource === files ? diffView.aiContext(file: files.cursor) : diffView.aiContext()
    }

    private func showAIDrawer() {
        if aiDrawer.superview != nil { return closeAIDrawer() }
        guard onPRScreen, let split = prScreen as? NSSplitView else { return }
        aiSource = window.firstResponder as? NSView
        split.arrangedSubviews.first?.isHidden = true
        split.addArrangedSubview(aiDrawer)
        let width = aiDrawer.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.45)
        width.priority = .init(900)
        width.isActive = true
        aiDrawer.begin()
        aiDrawer.setContext(aiContext().label)
        window.makeFirstResponder(aiDrawer)
    }

    private func closeAIDrawer() {
        guard aiDrawer.superview != nil else { return }
        cancelCopilot()
        aiDrawer.removeFromSuperview()
        (prScreen as? NSSplitView)?.arrangedSubviews.first?.isHidden = false
        let source = aiSource
        aiSource = nil
        window.makeFirstResponder(source ?? diffView)
    }

    private func cancelCopilot() {
        copilotTask?.cancel()
        copilotTask = nil
        copilotRunner?.cancel()
        copilotRunner = nil
        aiDrawer.isBusy = false
        aiDrawer.clearInput()
        aiDrawer.show("Cancelled.")
    }

    private func askCopilot(_ question: String) {
        guard let pr = current, let detail else { return }
        let checks = detail.checks.map { "\($0.symbol) \($0.name)" }.joined(separator: "\n")
        let context = aiContext()
        aiDrawer.setContext(context.label)
        let prompt = """
        Answer questions about this GitHub pull request. Do not edit files, run commands, commit, push, merge, close, or otherwise mutate anything.

        PR context:
        Repository: \(pr.repo.full)
        Number: #\(pr.number)
        State: OPEN
        Title: \(pr.title)
        Author: \(pr.author)
        Updated: \(pr.updatedAt)
        Checks:
        \(checks.isEmpty ? "none" : checks)

        Relevant diff context:
        \(context.text)

        User question:
        \(question)
        """
        aiDrawer.isBusy = true
        aiDrawer.show("Thinking…")
        let runner = CopilotRunner()
        copilotRunner = runner
        let model = Settings.copilotModel
        // Same directory every time for this PR, so Copilot's files persist across questions.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seer-copilot/\(pr.repo.owner)/\(pr.repo.name)/\(pr.number)")
        copilotTask = Task { [weak self] in
            let result = await Task.detached { runner.run(prompt, model: model, in: dir) }.value
            guard !Task.isCancelled, let self else { return }
            copilotRunner = nil
            copilotTask = nil
            aiDrawer.isBusy = false
            aiDrawer.show(result)
        }
    }

    private func setStatus(_ s: String, error: Bool = false) {
        busyText = nil
        busyTimer?.invalidate()
        busyTimer = nil
        status.stringValue = s
        status.textColor = error ? Theme.red : Theme.dim
    }

    /// Animated "⠹ text.." status; returns a token so only the latest operation clears it (see `endBusy`).
    @discardableResult
    private func setBusy(_ text: String) -> Int {
        busyID += 1
        busyText = text
        busyTick = 0
        tickBusy()
        if busyTimer == nil {
            busyTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickBusy() }
            }
        }
        return busyID
    }

    /// Replaces the busy status with `s`, unless a newer operation has started its own spinner.
    private func endBusy(_ id: Int, _ s: String) {
        if id == busyID { setStatus(s) }
    }

    private func tickBusy() {
        guard let t = busyText else { return }
        let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        status.stringValue = "\(frames[busyTick % frames.count]) \(t)" + String(repeating: ".", count: (busyTick / 4) % 4)
        status.textColor = Theme.accent
        busyTick += 1
    }

    private func copyCheckout(_ pr: PRSummary) {
        let cmd = "gh pr checkout \(pr.number) -R \(pr.repo.full)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        setStatus("Copied: \(cmd)")
    }

    /// Only https: check URLs come from third-party CI and could otherwise launch local apps or URL handlers.
    private func openURL(_ s: String) {
        guard let u = URL(string: s), u.scheme?.lowercased() == "https" else { return setStatus("Not opening non-https link: \(s)", error: true) }
        NSWorkspace.shared.open(u)
    }

    private func focusKey(_ c: Character) -> Bool {
        guard onPRScreen, !diffView.editorOpen else { return false }
        let target: NSView
        switch c {
        case _ where aiDrawer.superview != nil: target = c == "l" ? aiDrawer : diffView
        case "h": target = lastSidebar ?? files
        case "l": target = diffView
        case "k": target = checks
        default: target = files
        }
        if let l = target as? ListView { lastSidebar = l }
        window.makeFirstResponder(target)
        return true
    }

    // MARK: PR list

    private func showList() {
        closeAIDrawer()
        prMonitor?.invalidate()
        prMonitor = nil
        onPRScreen = false
        current = nil
        session = nil
        window.title = "Seer"
        updateMode()
        show(listScreen)
        search.isHidden = search.stringValue.isEmpty
        window.makeFirstResponder(prList)
    }

    private func showError(_ text: String) {
        setStatus(text.components(separatedBy: "\n").first ?? text, error: true)
        prList.rows = text.components(separatedBy: "\n").map {
            ListRow(text: NSAttributedString(string: $0, attributes: Theme.attrs(Theme.red, ui: true)), selectable: false)
        }
    }

    private func refresh(label: String = "Refreshing PRs", clearList: Bool = false) {
        guard let gh, let config else { return }
        if clearList {
            listItems = []
            prList.rows = []
        }
        let busy = setBusy(label)
        Task {
            do {
                let list = try await gh.listPRs(config.repos)
                PRCache.save(list)
                render(list)
                if list.warnings.isEmpty {
                    endBusy(busy, "Updated \(Date().formatted(date: .omitted, time: .shortened))")
                } else {
                    setStatus("Some repos failed: " + list.warnings.joined(separator: "; "), error: true)
                }
            } catch {
                setStatus("\(error)", error: true)
            }
        }
    }

    /// Puts each PR directly under the PR whose branch it is based on (stacked PRs), keeping the given order otherwise.
    private func stacked(_ prs: [PRSummary]) -> [(PRSummary, Int)] {
        let heads = Set(prs.map(\.headRef))
        let children = Dictionary(grouping: prs.filter { heads.contains($0.baseRef) && $0.baseRef != $0.headRef }, by: \.baseRef)
        var out: [(PRSummary, Int)] = []
        var seen = Set<Int>()
        func walk(_ pr: PRSummary, _ depth: Int) {
            guard seen.insert(pr.number).inserted else { return }
            out.append((pr, depth))
            children[pr.headRef]?.forEach { walk($0, depth + 1) }
        }
        prs.filter { !heads.contains($0.baseRef) || $0.baseRef == $0.headRef }.forEach { walk($0, 0) }
        prs.forEach { walk($0, 0) }
        return out
    }

    private func render(_ list: PRList) {
        guard let config else { return }
        lastList = list
        let words = search.stringValue.lowercased().split(separator: " ")
        let selected = listItems[safe: prList.cursor]??.url
        var rows: [ListRow] = []
        var items: [PRSummary?] = []
        for repo in config.repos {
            // review (0) → approved (1) → draft (2), then oldest first
            func state(_ pr: PRSummary) -> Int { pr.isDraft ? 2 : pr.isApproved && !pr.reviewRequested ? 1 : 0 }
            let prs = list.prs.filter { pr in
                let hay = "\(repo.full) #\(pr.number) \(pr.title)".lowercased()
                return pr.repo == repo && words.allSatisfy { hay.contains($0) }
            }.sorted { (state($0), $0.number) < (state($1), $1.number) }
            if prs.isEmpty && !words.isEmpty { continue }
            rows.append(ListRow(text: NSMutableAttributedString().ui("▾ ", Theme.dim).ui(repo.owner + "/", Theme.dim)
                .ui(repo.name, Theme.text, bold: true).ui("  ").pill("\(prs.count)", Theme.accent),
                selectable: false, background: Theme.panel))
            items.append(nil)
            if list.unavailable.contains(repo) {
                rows.append(ListRow(text: NSMutableAttributedString().ui("    unavailable (renamed, deleted or no access)", Theme.red),
                                    selectable: false))
                items.append(nil)
            } else if prs.isEmpty {
                rows.append(ListRow(text: NSMutableAttributedString().ui("    no open PRs", Theme.dim), selectable: false))
                items.append(nil)
            }
            for (pr, depth) in stacked(prs) {
                let s = NSMutableAttributedString().ui("  " + String(repeating: "   ", count: depth) + (depth > 0 ? "↳ " : ""))
                if pr.reviewRequested { s.pill("REVIEW", Theme.yellow).ui(" ") }
                if pr.isApproved && !pr.isDraft && !pr.reviewRequested { s.pill("APPROVED", Theme.green).ui(" ") }
                if pr.isDraft { s.pill("DRAFT", Theme.dim).ui(" ") }
                else if pr.changesRequested && !pr.reviewRequested { s.pill("CHANGES", Theme.red).ui(" ") }
                else if !pr.isApproved && !pr.reviewRequested { s.pill("PENDING", Theme.dim).ui(" ") }
                s.ui("#\(pr.number) ", Theme.dim)
                    .ui(pr.title, pr.isDraft ? Theme.dim : Theme.text, bold: pr.reviewRequested)
                    .ui("   \(pr.author)", Theme.purple)
                    .ui("   \(relativeAge(pr.createdAt))", Theme.dim)
                    .ui("   +\(pr.additions)", Theme.green)
                    .ui(" −\(pr.deletions) ", Theme.red)
                s.append(Theme.diffstat(pr.additions, pr.deletions))
                rows.append(ListRow(text: s))
                items.append(pr)
            }
        }
        let waiting = list.prs.filter(\.reviewRequested).count
        listHeader.title = NSMutableAttributedString().ui("Pull requests", Theme.text, bold: true)
            .ui("   \(list.prs.count) open", Theme.dim)
            .ui(waiting > 0 ? "   ·   " : "", Theme.dim).ui(waiting > 0 ? "\(waiting) awaiting your review" : "", Theme.yellow)
            .ui(list.viewer.isEmpty ? "" : "   ·   @\(list.viewer)", Theme.dim)
        listItems = items
        prList.rows = rows
        if let selected, let i = items.firstIndex(where: { $0?.url == selected }) { prList.setCursor(i) }
    }

    private func beginSearch() {
        search.isHidden = false
        window.makeFirstResponder(search)
    }

    private func endSearch(clear: Bool) {
        if clear {
            search.stringValue = ""
            search.isHidden = true
            if let lastList { render(lastList) }
        }
        window.makeFirstResponder(prList)
        if let i = listItems.firstIndex(where: { $0 != nil }), listItems[safe: prList.cursor] ?? nil == nil { prList.setCursor(i) }
    }

    private func schedulePrefetch(_ i: Int) {
        prefetch?.cancel()
        guard let pr = listItems[safe: i] ?? nil else { return }
        let work = DispatchWorkItem { [weak self] in _ = self?.entry(pr) }
        prefetch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Loading

    private func entry(_ pr: PRSummary) -> Entry? {
        guard let gh else { return nil }
        let k = key(pr)
        lru.removeAll { $0 == k }
        lru.append(k)
        if let e = entries[k] { return e }
        let load = Task.detached { () async throws -> Loaded in
            async let text = gh.diff(pr)
            async let detail = gh.detail(pr)
            return Loaded(diff: DiffParser.parse(try await text), detail: try await detail)
        }
        let highlight = Task.detached { () async -> [Int: [HLSpan]] in
            guard let l = try? await load.value else { return [:] }
            let wanted = l.diff.files.filter { Highlighter.language(forPath: $0.path) != nil && !$0.isBinary }
            let shas = wanted.flatMap { [$0.oldBlob, $0.newBlob].compactMap { $0 } }
            guard !shas.isEmpty, let blobs = try? await gh.blobs(pr.repo, shas: shas) else { return [:] }
            var sources: [Int: (old: String?, new: String?)] = [:]
            for (i, f) in l.diff.files.enumerated() where Highlighter.language(forPath: f.path) != nil {
                sources[i] = (f.oldBlob.flatMap { blobs[$0] }, f.newBlob.flatMap { blobs[$0] })
            }
            return Highlighter.highlight(diff: l.diff, sources: sources)
        }
        let e = Entry(load: load, highlight: highlight)
        entries[k] = e
        while lru.count > 10 { entries[lru.removeFirst()] = nil }
        return e
    }

    private func open(_ pr: PRSummary, reload: Bool = false) {
        if reload {
            let cacheKey = key(pr)
            entries[cacheKey] = nil
            lru.removeAll { $0 == cacheKey }
        }
        guard let e = entry(pr) else { return }
        current = pr
        let busy = setBusy(reload ? "Reloading #\(pr.number)" : "Loading #\(pr.number)")
        Task {
            do {
                let l = try await e.load.value
                guard current == pr, (!onPRScreen || reload) else { return endBusy(busy, "") }
                showPR(pr, l)
                let hl = await e.highlight.value
                guard current == pr else { return }
                diffView.highlights = hl
            } catch {
                entries[key(pr)] = nil
                guard current == pr else { return endBusy(busy, "") }
                current = nil
                setStatus("\(error)", error: true)
            }
        }
    }

    private func showPR(_ pr: PRSummary, _ l: Loaded) {
        guard let gh else { return }
        session = ReviewSession(pr: pr, detail: l.detail) { id, sha in try await gh.addReview(prId: id, commit: sha) }
        onPRScreen = true
        window.title = "\(pr.repo.full)#\(pr.number) — \(l.detail.title)"
        diffView.load(diff: l.diff, threads: l.detail.threads)

        renderPRHeader(pr)
        renderChecks()
        renderFiles()
        search.isHidden = true
        show(prScreen)
        window.makeFirstResponder(diffView)
        diffView.scrollToFile(0)
        hideOutdatedBanner()
        startPRMonitor()
        setStatus(session?.pendingReviewId != nil ? "You have a pending review. Space s to submit." : "")
    }

    private func startPRMonitor() {
        prMonitor?.invalidate()
        prMonitor = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCurrentPR() }
        }
    }

    /// Compares GitHub's head with the loaded one (1 GraphQL point); skipped while Seer is in the background.
    private func checkCurrentPR() {
        guard !prMonitorBusy, NSApp.isActive, onPRScreen, let gh, let s = session else { return }
        prMonitorBusy = true
        Task {
            defer { prMonitorBusy = false }
            guard let latest = try? await gh.headSha(s.pr), session === s else { return }
            if latest != s.detail.headSha { showOutdatedBanner() }
        }
    }

    private func reloadPR(_ pr: PRSummary? = nil) {
        guard let old = current else { return }
        hideOutdatedBanner()
        let next = pr ?? old
        let cacheKey = key(old)
        entries[cacheKey] = nil
        lru.removeAll { $0 == cacheKey }
        open(next, reload: true)
    }

    private func showOutdatedBanner() {
        guard outdatedBanner.superview == nil, onPRScreen else { return }
        container.addSubview(outdatedBanner)
        outdatedBanner.addSubview(outdatedLabel)
        NSLayoutConstraint.activate([
            outdatedBanner.topAnchor.constraint(equalTo: container.topAnchor),
            outdatedBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outdatedBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outdatedBanner.heightAnchor.constraint(equalToConstant: 42),
            outdatedLabel.leadingAnchor.constraint(equalTo: outdatedBanner.leadingAnchor, constant: 12),
            outdatedLabel.trailingAnchor.constraint(equalTo: outdatedBanner.trailingAnchor, constant: -12),
            outdatedLabel.centerYAnchor.constraint(equalTo: outdatedBanner.centerYAnchor),
        ])
    }

    private func hideOutdatedBanner() {
        outdatedBanner.removeFromSuperview()
    }

    private func renderPRHeader(_ pr: PRSummary) {
        guard let d = detail else { return }
        let t = NSMutableAttributedString().ui("#\(pr.number) ", Theme.dim).ui(d.title, Theme.text, bold: true)
            .ui("   \(pr.repo.full)", Theme.dim).ui("  ·  \(pr.author)", Theme.purple)
            .ui("  ·  opened \(relativeAge(pr.createdAt)) ago", Theme.dim)
            .ui("   +\(pr.additions)", Theme.green).ui(" −\(pr.deletions)", Theme.red)
        if session?.pendingReviewId != nil { t.ui("   ").pill("PENDING REVIEW", Theme.yellow) }
        prHeader.title = t
    }

    private func renderChecks() {
        guard let d = detail else { return }
        func color(_ s: CheckStatus) -> NSColor {
            switch s {
            case .success: return Theme.green
            case .failure: return Theme.red
            case .pending: return Theme.yellow
            case .neutral: return Theme.dim
            }
        }
        let mergeColor = d.mergeable == "MERGEABLE" ? Theme.green : d.mergeable == "CONFLICTING" ? Theme.red : Theme.dim
        let review = d.reviewDecision ?? "NO REVIEW"
        let reviewColor = review == "APPROVED" ? Theme.green : review == "CHANGES_REQUESTED" ? Theme.red : Theme.yellow
        var rows: [ListRow] = []
        if let pr = current {
            let plural = { (n: Int, w: String) in "\(n) \(w)\(n == 1 ? "" : "s")" }
            rows = [
                NSMutableAttributedString().ui(pr.author, Theme.purple).ui("  ·  #\(pr.number)", Theme.dim),
                NSMutableAttributedString().ui(pr.headRef, Theme.accent).ui(" → ", Theme.dim).ui(pr.baseRef, Theme.accent),
                NSMutableAttributedString().ui("\(plural(d.commitCount, "commit")) · \(plural(diffView.diff.files.count, "file"))  ", Theme.dim)
                    .ui("+\(pr.additions)", Theme.green).ui(" −\(pr.deletions)", Theme.red),
            ].map { ListRow(text: $0, selectable: false) }
        }
        rows.append(ListRow(text: NSMutableAttributedString().pill(d.mergeable, mergeColor).ui("  ")
            .pill(review.replacingOccurrences(of: "_", with: " "), reviewColor), selectable: false))
        if let auto = d.autoMerge {
            rows.append(ListRow(text: NSMutableAttributedString().ui("⟳ AUTO-MERGE ENABLED · \(auto)", Theme.orange, bold: true),
                                selectable: false, background: Theme.orange.withAlphaComponent(0.15)))
        }
        checksOffset = rows.count
        for c in d.checks {
            rows.append(ListRow(text: NSMutableAttributedString().ui(c.symbol + "  ", color(c.status)).ui(c.name)))
        }
        if d.checks.isEmpty {
            rows.append(ListRow(text: NSMutableAttributedString().ui("no checks", Theme.dim), selectable: false))
        }
        checks.rows = rows
        let title = NSMutableAttributedString().ui("CHECKS", Theme.dim, bold: true)
        for status in [CheckStatus.success, .failure, .pending] {
            let matching = d.checks.filter { $0.status == status }
            if let c = matching.first { title.ui("   \(c.symbol) \(matching.count)", color(status)) }
        }
        checksHeader.title = title
    }

    private func renderFiles() {
        let counts = Dictionary(diffView.threads.map { ($0.path, $0.comments.count) }, uniquingKeysWith: +)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingHead
        let fs = diffView.diff.files
        files.rows = fs.map { f in
            let s = NSMutableAttributedString().ui(f.path).ui("  +\(f.adds)", Theme.green).ui(" −\(f.dels)", Theme.red)
                .ui(counts[f.path].map { "  \($0)" } ?? "", Theme.yellow)
            s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
            return ListRow(text: s)
        }
        filesHeader.title = NSMutableAttributedString().ui("FILES", Theme.dim, bold: true).ui("   \(fs.count)", Theme.text)
            .ui("   +\(fs.reduce(0) { $0 + $1.adds })", Theme.green).ui(" −\(fs.reduce(0) { $0 + $1.dels })", Theme.red)
    }

    private func prCommand(_ cmd: Command) -> Bool {
        switch cmd {
        case .other("?"):
            showHelp()
        case .ai:
            showAIDrawer()
        case .other("R"):
            reloadPR()
        case .back:
            showList()
        case .open:
            if let d = detail { openURL(d.url) }
        case .submit:
            beginSubmit()
        case .merge:
            beginMerge()
        case .checkout:
            if let pr = current { copyCheckout(pr) }
        case .other("X"):
            beginClose()
        case .other(","):
            openSettings()
        default:
            return false
        }
        return true
    }

    // MARK: Reviews

    private func beginComment(_ t: CommentTarget, text: String = "", note: String = "") {
        diffView.openEditor(title: "\(note)Comment on \(t.label)", text: text) { [weak self] body in
            self?.postComment(t, body)
        }
    }

    /// Shared flow for comment, reply and edit: validate, run `work`, then apply its UI update if the same load is on screen.
    private func post(_ body: String, discarded: String, busy: String, posted: String, applied: String,
                      retry: @escaping (String) -> Void, _ work: @escaping (ReviewSession) async throws -> () -> Void) {
        guard let s = session else { return }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return setStatus(discarded) }
        setBusy(busy)
        Task {
            do {
                let apply = try await work(s)
                entries[key(s.pr)] = nil
                guard session === s else { return setStatus(posted) }
                apply()
                setStatus(applied)
            } catch {
                setStatus("\(error)", error: true)
                // Reopen with the text so a failed post doesn't lose it.
                if session === s { retry(body) }
            }
        }
    }

    private func postComment(_ t: CommentTarget, _ body: String) {
        guard let gh else { return }
        post(body, discarded: "Empty comment discarded", busy: "Posting comment on \(t.label)", posted: "Comment posted",
             applied: "Comment added to your pending review. Space s to submit.",
             retry: { [self] in beginComment(t, text: $0, note: "FAILED, ⏎ to retry. ") }) { [self] s in
            let id = try await s.ensureReview()
            let ids = try await gh.addThread(reviewId: id, path: t.path, line: t.line, side: t.side,
                                             startLine: t.startLine, startSide: t.startSide, body: body)
            return { [self] in
                diffView.addThread(ReviewThread(id: ids.thread, path: t.path, line: t.line, side: t.side, resolved: false,
                                                resolvedBy: nil,
                                                comments: [ReviewComment(id: ids.comment, author: s.detail.viewer, body: body, canEdit: true)]))
                renderFiles()
                renderPRHeader(s.pr)
            }
        }
    }

    private func beginReply(_ threadId: String, text: String = "", note: String = "") {
        guard let th = diffView.threads.first(where: { $0.id == threadId }) else { return }
        let who = th.comments.first.map { " @\($0.author)" } ?? ""
        diffView.openEditor(title: "\(note)Reply to\(who) on \(th.path):\(th.line)", text: text) { [weak self] body in
            self?.postReply(threadId, body)
        }
    }

    private func postReply(_ threadId: String, _ body: String) {
        guard let gh else { return }
        post(body, discarded: "Empty reply discarded", busy: "Posting reply", posted: "Reply posted",
             applied: "Reply added to your pending review. Space s to submit.",
             retry: { [self] in beginReply(threadId, text: $0, note: "FAILED, ⏎ to retry. ") }) { [self] s in
            let id = try await s.ensureReview()
            let cid = try await gh.reply(threadId: threadId, reviewId: id, body: body)
            return { [self] in
                diffView.appendComment(thread: threadId, ReviewComment(id: cid, author: s.detail.viewer, body: body, canEdit: true))
                renderFiles()
                renderPRHeader(s.pr)
            }
        }
    }

    private func beginEdit(_ threadId: String, _ commentId: String, text: String? = nil, note: String = "") {
        guard let comment = diffView.threads.first(where: { $0.id == threadId })?.comments.first(where: { $0.id == commentId })
        else { return }
        guard comment.canEdit else {
            NSSound.beep()
            return setStatus("You can't edit @\(comment.author)'s comment. Press c to reply instead.")
        }
        diffView.openEditor(title: "\(note)Edit comment", text: text ?? comment.body) { [weak self] body in
            self?.postEdit(threadId, commentId, body)
        }
    }

    private func postEdit(_ threadId: String, _ commentId: String, _ body: String) {
        guard let gh else { return }
        post(body, discarded: "Empty edit discarded", busy: "Saving edit", posted: "Comment updated", applied: "Comment updated",
             retry: { [self] in beginEdit(threadId, commentId, text: $0, note: "FAILED, ⏎ to retry. ") }) { [self] _ in
            try await gh.editComment(id: commentId, body: body)
            return { [self] in diffView.updateComment(thread: threadId, comment: commentId, body: body) }
        }
    }

    /// Refuses up front when the banner already shows new commits; `merge` re-checks with GitHub before merging.
    private func beginMerge(method: String? = nil, text: String? = nil, note: String = "") {
        guard let d = detail, let pr = current, mergeModal.superview == nil else { return }
        guard outdatedBanner.superview == nil else { return setStatus(ReviewBlock.newCommits.description, error: true) }
        let bodies = d.commitBodies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let squashBody: String
        if d.commitHeadlines.count == 1 {
            squashBody = bodies.first ?? ""
        } else {
            squashBody = zip(d.commitHeadlines, bodies).map { h, b in
                b.isEmpty ? "* \(h)" : "* \(h)\n\n" + b.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        let drafts = [
            MergeMethod.merge.rawValue: "Merge pull request #\(pr.number) from \(d.headOwner)/\(pr.headRef)\n\n\(d.title)",
            MergeMethod.squash.rawValue: squashBody.isEmpty ? d.title : "\(d.title)\n\n\(squashBody)",
            MergeMethod.rebase.rawValue: "",
        ]
        setStatus("")
        fill(container, with: mergeModal)
        mergeModal.begin(drafts: drafts, mode: method, text: text, note: note)
    }

    private func fill(_ parent: NSView, with v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor), v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor), v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    private func closeMerge() {
        mergeModal.removeFromSuperview()
        window.makeFirstResponder(diffView)
    }

    /// Shows why approving/merging was refused; the banner offers the reload.
    private func blocked(_ b: ReviewBlock, _ s: ReviewSession) {
        setStatus(b.description, error: true)
        if b == .newCommits, session === s { showOutdatedBanner() }
    }

    private func merge(_ id: String, _ text: String) {
        guard let gh, let s = session, let method = MergeMethod(rawValue: id) else { return }
        let pr = s.pr, d = s.detail
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headline = lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let body = lines.dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = method != .rebase
        setBusy("Merging #\(pr.number)")
        Task {
            do {
                try s.checkCurrent(latestHead: try await gh.headSha(pr), approving: false)
                // expectedHead makes GitHub refuse too if a push lands between the check and the merge.
                try await gh.mergePR(id: d.id, method: method, expectedHead: d.headSha,
                                     headline: custom && !headline.isEmpty ? headline : nil,
                                     body: custom && !body.isEmpty ? body : nil)
                entries[key(pr)] = nil
                if session === s { showList() }
                refresh(label: "Merged #\(pr.number) · refreshing PRs")
            } catch let b as ReviewBlock {
                blocked(b, s)
            } catch {
                setStatus("\(error)", error: true)
                if session === s { beginMerge(method: id, text: text, note: "FAILED, Enter to retry · ") }
            }
        }
    }

    private func beginClose(text: String = "", note: String = "") {
        guard current != nil, closeModal.superview == nil else { return }
        setStatus("")
        fill(container, with: closeModal)
        closeModal.begin(mode: "CLOSE", text: text, note: note)
    }

    private func closeCloseModal() {
        closeModal.removeFromSuperview()
        window.makeFirstResponder(diffView)
    }

    private func close(_ comment: String) {
        guard let gh, let pr = current, let d = detail else { return }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        setBusy("Closing #\(pr.number)")
        Task {
            do {
                try await gh.closePR(id: d.id, comment: comment)
                entries[key(pr)] = nil
                if current == pr { showList() }
                refresh(label: "Closed #\(pr.number) · refreshing PRs")
            } catch {
                setStatus("\(error)", error: true)
                if current == pr { beginClose(text: comment, note: "FAILED, Enter to retry · ") }
            }
        }
    }

    private func beginSubmit(event: String? = nil, text: String = "", note: String = "") {
        guard submitModal.superview == nil else { return }
        setStatus("")
        fill(container, with: submitModal)
        submitModal.begin(mode: event, text: text, note: note)
    }

    private func closeSubmit() {
        submitModal.removeFromSuperview()
        window.makeFirstResponder(diffView)
    }

    private func submit(_ id: String, _ name: String, _ body: String) {
        guard let gh, let s = session, let event = ReviewEvent(rawValue: id) else { return }
        setBusy("Submitting review")
        Task {
            do {
                if event == .approve { try s.checkCurrent(latestHead: try await gh.headSha(s.pr), approving: true) }
                let reviewId = try await s.ensureReview()
                try await gh.submitReview(reviewId: reviewId, event: event, body: body)
                s.submitted()
                entries[key(s.pr)] = nil
                if session === s { renderPRHeader(s.pr) }
                setStatus("Review submitted: \(name)")
            } catch let b as ReviewBlock {
                blocked(b, s)
            } catch {
                setStatus("\(error)", error: true)
                if session === s { beginSubmit(event: id, text: body, note: "FAILED, Enter to retry · ") }
            }
        }
    }
}

extension AppController: NSTextFieldDelegate {
    func controlTextDidChange(_: Notification) {
        if let lastList { render(lastList) }
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): endSearch(clear: false)
        case #selector(NSResponder.cancelOperation(_:)): endSearch(clear: true)
        default: return false
        }
        return true
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
