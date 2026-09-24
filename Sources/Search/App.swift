import SwiftUI
import AppKit

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct SearchApp: App {
    @StateObject private var browser = Browser()
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    var body: some Scene {
        Window("Search", id: "browser") {
            ContentView(browser: browser)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            // One window. Tabs are the only kind of "new" there is.
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { browser.newTab() }
                    .keyboardShortcut(browser.keys.menu(.newTab))
                Button("New Private Tab") { browser.newShyTab() }
                    .keyboardShortcut(browser.keys.menu(.newPrivateTab))
                Button("Reopen Closed Tab") { browser.reopen() }
                    .keyboardShortcut(browser.keys.menu(.reopenTab))
                    .disabled(browser.ghosts.isEmpty)
                Divider()
                Button("Open Address…") { browser.edit() }
                    .keyboardShortcut(browser.keys.menu(.address))
                Divider()
                Button("Close Tab") { if let tab = browser.active { browser.close(tab) } }
                    .keyboardShortcut(browser.keys.menu(.closeTab))
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { browser.printPage() }
                    .keyboardShortcut(browser.keys.menu(.print))
                    .disabled(browser.active?.isBlank ?? true)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find on Page…") { browser.openFind() }
                    .keyboardShortcut(browser.keys.menu(.findOnPage))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Find Next") { browser.look(forward: true) }
                    .keyboardShortcut(browser.keys.menu(.findNext))
                    .disabled(!browser.finding)
                Button("Find Previous") { browser.look(forward: false) }
                    .keyboardShortcut(browser.keys.menu(.findPrevious))
                    .disabled(!browser.finding)
            }
            CommandGroup(replacing: .toolbar) {
                Toggle("Show Tabs in Sidebar", isOn: Binding(
                    get: { browser.prefs.sidebar },
                    set: { _ in browser.toggleSidebar() }
                ))
                .keyboardShortcut(browser.keys.menu(.sidebar))
                Button(browser.prefs.bare ? "Show Sidebar" : "Hide Sidebar") { browser.toggleBare() }
                    .disabled(!browser.prefs.sidebar)
                    .keyboardShortcut(browser.keys.menu(.hideTabs))
                Picker("Tabs Wear", selection: Binding(
                    get: { browser.prefs.glyph },
                    set: { browser.prefs.glyph = $0 }
                )) {
                    ForEach(Glyph.allCases) { glyph in
                        Text(glyph.title).tag(glyph)
                    }
                }
                Divider()
                Button("Reload Page") { browser.reload() }
                    .keyboardShortcut(browser.keys.menu(.reload))
                Button("Reload Without Cache") { browser.hardReload() }
                    .keyboardShortcut(browser.keys.menu(.hardReload))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Reading Mode") { browser.toggleReader() }
                    .keyboardShortcut(browser.keys.menu(.readingMode))
                Button("Float Video") { browser.toggleFloat() }
                    .keyboardShortcut(browser.keys.menu(.floatVideo))
                Divider()
                Button("Hide Elements…") { browser.toggleHiding() }
                    .keyboardShortcut(browser.keys.menu(.hideElements))
                Button("Hidden on This Site…") { browser.reviewing.toggle() }
                    .keyboardShortcut(browser.keys.menu(.hiddenHere))
                Divider()
                Button("Zoom In") { browser.zoom(by: 1.1) }
                    .keyboardShortcut(browser.keys.menu(.zoomIn))
                Button("Zoom Out") { browser.zoom(by: 1 / 1.1) }
                    .keyboardShortcut(browser.keys.menu(.zoomOut))
                Button("Actual Size") { browser.resetZoom() }
                    .keyboardShortcut(browser.keys.menu(.actualSize))
                Divider()
                Button("Show Web Inspector") { browser.inspect() }
                    .keyboardShortcut(browser.keys.menu(.inspector))
                    .disabled(browser.active?.isBlank ?? true)
            }
            CommandMenu("Tabs") {
                Button("Back") { browser.back() }
                    .keyboardShortcut(browser.keys.menu(.back))
                    .disabled(browser.active?.canGoBack != true)
                Button("Forward") { browser.forward() }
                    .keyboardShortcut(browser.keys.menu(.forward))
                    .disabled(browser.active?.canGoForward != true)
                Divider()
                Button("Next Tab") { browser.step(1) }
                    .keyboardShortcut(browser.keys.menu(.nextTab))
                Button("Previous Tab") { browser.step(-1) }
                    .keyboardShortcut(browser.keys.menu(.previousTab))
                Button("Search Tabs…") { browser.summon() }
                    .keyboardShortcut(browser.keys.menu(.switchTab))
                Divider()
                Section("Profiles") {
                    // Every key here is taken in the key monitor below, before
                    // any page sees it; the shortcut on the item is for the eye.
                    ForEach(Array(browser.profileNames.enumerated()), id: \.offset) { index, name in
                        let on = Binding(get: { browser.profile == index }, set: { _ in browser.switchProfile(to: index) })
                        if index < 9 {
                            Toggle(name, isOn: on)
                                .keyboardShortcut(browser.keys.menu(.profileNumber, digit: index + 1))
                        } else {
                            Toggle(name, isOn: on)
                        }
                    }
                    Button("Previous Profile") { browser.stepProfile(-1) }
                        .keyboardShortcut(browser.keys.menu(.previousProfile))
                        .disabled(browser.profileNames.count < 2)
                    Button("Next Profile") { browser.stepProfile(1) }
                        .keyboardShortcut(browser.keys.menu(.nextProfile))
                        .disabled(browser.profileNames.count < 2)
                    Button("New Profile…") { browser.newProfile() }
                        .keyboardShortcut(browser.keys.menu(.newProfile))
                    Button("Rename Profile…") { browser.renameProfile() }
                    Button("Delete Profile…") { browser.deleteCurrentProfile() }
                        .disabled(browser.profileNames.count < 2)
                }
                Divider()
                if let tab = browser.active {
                    if tab.pin == nil {
                        Button("Pin Tab") { browser.pin(tab) }
                            .keyboardShortcut(browser.keys.menu(.pinTab))
                            .disabled(tab.isBlank)
                    } else {
                        Button("Change Letter") { browser.editLetter(tab) }
                        Button("Unpin Tab") { browser.unpin(tab) }
                            .keyboardShortcut(browser.keys.menu(.pinTab))
                    }
                }
                Button("Duplicate Tab") { browser.duplicate() }
                    .keyboardShortcut(browser.keys.menu(.duplicate))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Copy Address") { browser.copyAddress() }
                    .keyboardShortcut(browser.keys.menu(.copyAddress))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Paste and Go") { browser.pasteAndGo() }
                    .keyboardShortcut(browser.keys.menu(.pasteAndGo))
                Divider()
                Button("Close Other Tabs") { if let tab = browser.active { browser.closeOthers(but: tab) } }
                    .keyboardShortcut(browser.keys.menu(.closeOthers))
                    .disabled(browser.tabs.count < 2)
                Button("Stop Sound in Tab") { browser.pauseMedia() }
                    .keyboardShortcut(browser.keys.menu(.muteTab))
            }
            CommandMenu("Bookmarks") {
                Button("Add This Page") { browser.bookmarkCurrent() }
                    .keyboardShortcut(browser.keys.menu(.bookmark))
                    .disabled(browser.active?.isBlank ?? true)
                Button("Show Bookmarks…") { browser.bookmarking = true }
                    .keyboardShortcut(browser.keys.menu(.bookmarks))
                Divider()
                BookmarkTree(nodes: browser.bookmarks.roots) { browser.visit($0) }
            }
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button {
                            browser.open(trace.url, foreground: true)
                        } label: {
                            MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
                        }
                    }
                }
                if !browser.ghosts.isEmpty {
                    Section("Recently Closed") {
                        ForEach(browser.ghosts.reversed().prefix(10)) { ghost in
                            Button {
                                browser.reopen(ghost)
                            } label: {
                                MenuLine(title: ghost.label, url: ghost.url)
                            }
                        }
                    }
                }
                Divider()
                Button("Show History…") { browser.recalling = true }
                    .keyboardShortcut(browser.keys.menu(.history))
                Button("Downloads…") { browser.hoarding = true }
                    .keyboardShortcut(browser.keys.menu(.downloads))
                Divider()
                Button("Clear History") { browser.clearHistory() }
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") { browser.tuning = true }
                    .keyboardShortcut(browser.keys.menu(.settings))
                Button("Welcome…") { browser.welcoming = true }
                    .keyboardShortcut(browser.keys.menu(.welcome))
                Button("Passwords…") { browser.managing = true }
                    .keyboardShortcut(browser.keys.menu(.passwords))
            }
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { Links.writeFeedback() }
            }
        }
    }
}

/// The bookmarks, as menus within menus, for the menu bar.
private struct BookmarkTree: View {
    let nodes: [Bookmark]
    let open: (URL) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                Menu(node.title) {
                    if let kids = node.children, !kids.isEmpty {
                        BookmarkTree(nodes: kids, open: open)
                    } else {
                        Text("Empty")
                    }
                }
            } else if let text = node.url, let url = URL(string: text) {
                Button(node.title) { open(url) }
            }
        }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let host = url.host()?.lowercased(),
           let icon = Favicons.shared.cached(host) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

struct ContentView: View {
    @ObservedObject var browser: Browser

    @State private var keys: Any?
    @State private var window: NSWindow?
    @State private var resting: RestingLights?


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: .top) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            (browser.active?.immersed == true ? Color.black : Palette.ground)

            HStack(spacing: 0) {
                // The column of tabs, in the way that has one. It takes the
                // full height, so the traffic lights sit in its own corner
                // rather than over the page.
                if sidebar {
                    SideBar(browser: browser, prefs: browser.prefs)
                        .transition(.move(edge: .leading))
                }

                VStack(spacing: 0) {
                    // Room for the traffic lights, and for the strip when there
                    // is one. The page starts under it, not behind it — a page
                    // sliding beneath floating chrome is a browser showing off,
                    // and it costs a compositing pass.
                    Color.clear.frame(height: band)

                    // One stage, always.
                    if let tab = browser.active {
                        Page(tab: tab)
                            .overlay(alignment: .topTrailing) {
                                if browser.finding {
                                    FindBar(browser: browser)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if let asked = browser.suggesting, asked.tab == tab.id {
                                    AccountList(browser: browser, asked: asked)
                                        .transition(.opacity)
                                }
                            }
                            .animation(Motion.quick, value: browser.suggesting)
                    } else {
                        Palette.ground
                    }
                }
            }

            if !browser.prefs.sidebar, browser.active?.immersed != true {
                TabBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // With the column put away, the lights' corner is still there to
            // take hold of the window by, and the left edge brings the
            // column out over the page for as long as the pointer is on it.
            if tucked {
                DragStrip()
                    .frame(width: Metrics.lights, height: Metrics.strip)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onHover { if $0 { browser.peeking = true } }
                        .padding(.top, Metrics.strip)
                    Spacer(minLength: 0)
                }
                if browser.peeking {
                    HStack(spacing: 0) {
                        SideBar(browser: browser, prefs: browser.prefs)
                            .background(Palette.ground)
                            .shadow(color: .black.opacity(0.18), radius: 24, x: 6)
                            .onHover { if !$0 { browser.peeking = false } }
                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .leading))
                }
            }
        }
        .ignoresSafeArea()
        .animation(Motion.glide, value: browser.prefs.sidebar)
        .animation(Motion.glide, value: browser.prefs.bare)
        .animation(Motion.settle, value: browser.peeking)
        .animation(.easeOut(duration: 0.12), value: browser.active?.immersed)
    }

    /// Everything that rises from the bottom edge to say one thing.
    private var bars: some View {
        VStack(spacing: 8) {
            announcement
            if let ask = browser.asking {
                captureAsking(ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let offer = browser.offering {
                keepAsking(offer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StoreOffer(browser: browser)
            if browser.veiling {
                hint("Click anything to hide it   ⌘Z undo   esc done")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: browser.veiling)
        .animation(Motion.settle, value: browser.asking)
        .animation(Motion.settle, value: browser.offering)
    }

    /// The address field: raised over a page by ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        if browser.fieldShowing {
            Omnibox(browser: browser, over: !(browser.active?.isBlank ?? true))
                // Centred on the page, not on the window. The column of tabs
                // is not what the field is standing over, and dimming it along
                // with the page says otherwise.
                .padding(.leading, sidebar ? browser.prefs.sideWidth : 0)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            sheet { HistoryPanel(browser: browser) } close: { browser.recalling = false }
        }
        if browser.hoarding {
            sheet { DownloadsPanel(browser: browser, loot: browser.loot) }
                close: { browser.hoarding = false }
        }
        if browser.tuning {
            sheet { SettingsPanel(browser: browser, prefs: browser.prefs) }
                close: { browser.tuning = false }
        }
        if browser.bookmarking {
            sheet { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
                close: { browser.bookmarking = false }
        }
        if browser.welcoming {
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
        }
        if browser.managing {
            sheet { PasswordsPanel(browser: browser) } close: { browser.managing = false }
        }
        if browser.reviewing {
            // No dimming for this one: the whole point is to keep looking at
            // the page while the list offers to put things back on it.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.reviewing = false }
                HiddenPanel(browser: browser)
                    .padding(.top, Metrics.strip + 8)
                    .padding(.trailing, 14)
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    var body: some View {
        window_
            .overlay(alignment: .bottom) { bars }
            .overlay { field }
            .overlay { panels }
            .animation(Motion.settle, value: browser.fieldShowing)
            .background(WindowSetup { window = $0; dress($0) })
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { measureLights() }
            }
            // Stepping away to another app: macOS draws its own resting
            // buttons, and on a light window they come out nearly white. Ours
            // go on in their place until the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                // Another app in front: the pointer is no longer over the page.
                browser.active?.built?.pointerLeft()
                measureLights()
                resting?.isHidden = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resting?.isHidden = true
            }
            .onChange(of: browser.fieldShowing) { _, showing in
                if showing {
                    DispatchQueue.main.async { browser.askFocus() }
                } else {
                    handBack()
                }
            }
            .onChange(of: browser.activeID) { _, _ in handBack() }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            watchKeys()
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
        }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack() {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        DispatchQueue.main.async {
            guard let web = browser.active?.web, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// A page asking to see or hear you. Named by the site, in its own words,
    /// with the answer remembered so it is asked once and not every call.
    private func captureAsking(_ ask: Browser.CaptureAsk) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ask.wants == "microphone" ? "mic" : ask.wants == "notifications" ? "bell" : "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(ask.wants == "notifications"
                 ? "\(ask.host) wants to send you notifications"
                 : "\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { browser.allowCapture() } label: {
                Text("Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { browser.denyCapture() } label: {
                Text("Don't allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    /// Offered once, answered once. The password is never shown back to you —
    /// there is nothing to be learned from reading your own password.
    private func keepAsking(_ offer: Browser.Offer) -> some View {
        let login = offer.login
        return HStack(spacing: 12) {
            Text(offer.changed
                 ? "Update the password for \(login.user) on \(login.host)?"
                 : (login.user.isEmpty
                    ? "Save this password for \(login.host)?"
                    : "Save the password for \(login.user) on \(login.host)?"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button(offer.changed ? "Update" : "Save") { browser.keepOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Not now") { browser.dropOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if !offer.changed {
                Button("Never here") { browser.neverOffer() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }


    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ground.opacity(0.92))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    @ViewBuilder
    private func sheet<Panel: View>(
        @ViewBuilder _ panel: () -> Panel,
        close: @escaping () -> Void
    ) -> some View {
        ZStack {
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    /// True while the tabs are down the left.
    private var sidebar: Bool {
        browser.prefs.sidebar && !browser.prefs.bare && browser.active?.immersed != true
    }

    /// The column put away with ⌘S. Only a column can be: tabs across the
    /// top stay where they are.
    private var tucked: Bool {
        browser.prefs.sidebar && browser.prefs.bare && browser.active?.immersed != true
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top; the strip needs a band.
    private var band: CGFloat {
        // With the tabs put away the page has the top too; the lights sit
        // over its corner, as they do over a full-screen page.
        guard browser.active?.immersed != true else { return 0 }
        return browser.prefs.sidebar ? 0 : Metrics.strip
    }

    /// Put the resting circles in the title bar, exactly over the buttons.
    private func measureLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        let view = resting ?? RestingLights()
        if view.superview !== titlebar {
            view.frame = titlebar.bounds
            view.autoresizingMask = [.width, .height]
            titlebar.addSubview(view, positioned: .above, relativeTo: nil)
            resting = view
        }
        view.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        view.isHidden = NSApp.isActive
    }

    private func dress(_ window: NSWindow) {
        Links.window = window
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Palette.NS.ground
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text — and the window's own dragging is
        // off altogether. With the title bar hidden, AppKit still treats the
        // top of the window as one: a press on any see-through view there
        // that nothing claimed moved the window. The tabs sit in a scroll
        // view whose views claim nothing, so dragging a tab dragged the
        // window. The strips move the window themselves and don't need this.
        window.isMovableByWindowBackground = false
        window.isMovable = false
        // Where you left it, at the size you left it. A test run keeps its
        // own: the name lives in the app's standard defaults, which every
        // copy shares, and a probe resized for a test once changed the size
        // the real window came back at.
        window.setFrameAutosaveName(Store.world.map { "search (\($0))" } ?? "search")

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window) { measureLights() }
        DispatchQueue.main.async { measureLights() }

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }

    // MARK: - keys

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else {
                // ⌘ let go of ends a ⌘K walk, ⌃ let go of a ⌃Tab walk —
                // wherever each stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                if let held = browser.keys.chord(for: .recentTab),
                   (held.control && !event.modifierFlags.contains(.control))
                    || (held.option && !event.modifierFlags.contains(.option))
                    || (held.command && !event.modifierFlags.contains(.command)) {
                    browser.landWalk()
                }
                return event
            }
            return take(event) ? nil : event
        }
    }

    private func take(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // A key being recorded in Settings › Shortcuts: this press is it.
        if browser.keys.recording != nil { return browser.keys.record(event) }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.tuning {
                browser.tuning = false
                return true
            }
            if browser.bookmarking {
                browser.bookmarking = false
                return true
            }
            if browser.managing {
                browser.managing = false
                return true
            }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            // One step at a time: the list first, then the field.
            if browser.picked != nil {
                browser.picked = nil
                return true
            }
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        // Tab is the page's, as in every other browser: it moves between
        // the things on the page that can take the keyboard. Only while an
        // address is being typed is it the field's — it walks the list
        // under the field, or takes the ending the field is offering.
        if event.keyCode == 48, flags.isSubset(of: .shift) {
            if browser.editingTab != nil { return true }
            guard browser.fieldShowing else { return false }
            if !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
            } else {
                browser.acceptEnding()
            }
            return true
        }

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, since
        // none of ours use those.
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           Extensions.shared.take(event) {
            return true
        }

        // Everything else is a key in the map, yours or the app's own.
        guard let chord = Chord(event: event) else { return false }
        // ⌘Z while pointing: the last thing hidden comes back. Everywhere
        // else undo belongs to the page.
        if chord == Chord(key: "z", command: true), browser.veiling {
            browser.undoHiding()
            return true
        }
        if let command = browser.keys.command(for: chord) {
            perform(command)
            return true
        }
        // The nine tabs and the nine profiles: whatever modifiers were
        // given to the 1 go for 2 to 9 as well. The ninth tab is the last
        // one, however many there are.
        if chord.key.count == 1, let digit = Int(chord.key), (1...9).contains(digit) {
            let one = chord.with(key: "1")
            if one == browser.keys.chord(for: .tabNumber) {
                browser.select(index: digit == 9 ? browser.tabs.count - 1 : digit - 1)
                return true
            }
            if one == browser.keys.chord(for: .profileNumber) {
                browser.switchProfile(to: digit - 1)
                return true
            }
        }
        if let own = browser.keys.custom(for: chord), let url = Google.destination(for: own.url) {
            browser.visit(url)
            return true
        }
        // ⌘← and ⌘→, for hands that never learned the brackets.
        if chord == Chord(key: "left", command: true) { browser.back(); return true }
        if chord == Chord(key: "right", command: true) { browser.forward(); return true }
        return false
    }

    /// One of the app's own commands, by name.
    private func perform(_ command: Keys.Command) {
        switch command {
        case .newTab: browser.newTab()
        case .newPrivateTab: browser.newShyTab()
        case .reopenTab: browser.reopen()
        case .closeTab: if let tab = browser.active { browser.close(tab) }
        case .closeOthers: if let tab = browser.active { browser.closeOthers(but: tab) }
        case .duplicate: browser.duplicate()
        case .pinTab: browser.togglePin()
        case .address: browser.edit()
        case .switchTab:
            // Held down, ⌘K walks the list a step at a time; letting go of ⌘
            // takes wherever it stopped.
            if browser.editing, !browser.offers.isEmpty {
                browser.stepSummon()
            } else {
                browser.summon()
            }
        case .tabNumber, .profileNumber: break
        case .nextTab: browser.step(1)
        case .previousTab: browser.step(-1)
        case .recentTab: browser.walkTabs(1)
        case .recentTabBack: browser.walkTabs(-1)
        case .back: browser.back()
        case .forward: browser.forward()
        case .reload: browser.reload()
        case .hardReload: browser.hardReload()
        case .findOnPage: browser.openFind()
        case .findNext: browser.look(forward: true)
        case .findPrevious: browser.look(forward: false)
        case .print: browser.printPage()
        case .copyAddress: browser.copyAddress()
        case .pasteAndGo: browser.pasteAndGo()
        case .bookmark: browser.bookmarkCurrent()
        case .bookmarks: browser.bookmarking.toggle()
        case .history: browser.recalling.toggle()
        case .downloads: browser.hoarding.toggle()
        case .muteTab: browser.pauseMedia()
        case .readingMode: browser.toggleReader()
        case .floatVideo: browser.toggleFloat()
        case .hideElements: browser.toggleHiding()
        case .hiddenHere: browser.reviewing.toggle()
        case .zoomIn: browser.zoom(by: 1.1)
        case .zoomOut: browser.zoom(by: 1 / 1.1)
        case .actualSize: browser.resetZoom()
        case .inspector: browser.inspect()
        case .sidebar: browser.toggleSidebar()
        case .hideTabs: browser.toggleBare()
        case .settings: browser.tuning.toggle()
        case .passwords: browser.managing.toggle()
        case .welcome: browser.welcoming.toggle()
        case .previousProfile: browser.stepProfile(-1)
        case .nextProfile: browser.stepProfile(1)
        case .newProfile: browser.newProfile()
        }
    }
}
