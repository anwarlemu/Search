import SwiftUI

// Every shortcut the app answers to, and the keys it answers with — yours,
// once you change one. One dictionary in the settings, read once at launch;
// a key press is one lookup. Settings › Shortcuts is where they are changed,
// and where a key of your own can be given a page to open.

/// A key with its modifiers, as pressed.
struct Chord: Hashable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    /// Keys that aren't a character, by key code.
    private static let named: [UInt16: String] = [
        48: "tab", 53: "esc", 36: "return", 76: "return", 49: "space", 51: "delete", 117: "forwarddelete",
        123: "left", 124: "right", 125: "up", 126: "down", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12",
    ]

    private static let glyphs: [String: String] = [
        "tab": "⇥", "esc": "⎋", "return": "↩", "space": "␣", "delete": "⌫", "forwarddelete": "⌦",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let name = Chord.named[event.keyCode] {
            key = name
        } else {
            guard var text = event.charactersIgnoringModifiers?.lowercased(), text.count == 1 else { return nil }
            // ⌘+ arrives as "=" or "+" depending on the keyboard: one key.
            if text == "+" { text = "=" }
            key = text
        }
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }

    /// From "ctrl+opt+shift+cmd+r", as kept in the settings.
    init?(_ text: String) {
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        key = last
        for part in parts {
            switch part {
            case "cmd": command = true
            case "shift": shift = true
            case "opt": option = true
            case "ctrl": control = true
            default: return nil
            }
        }
    }

    var text: String {
        ([control ? "ctrl" : nil, option ? "opt" : nil, shift ? "shift" : nil, command ? "cmd" : nil].compactMap { $0 } + [key])
            .joined(separator: "+")
    }

    /// "⌃⌥⇧⌘R", for the eye.
    var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (Chord.glyphs[key] ?? key.uppercased())
    }

    /// A shortcut has a modifier a page wouldn't be typing with, or is a
    /// function key. A bare letter can't be a shortcut in a browser.
    var usable: Bool {
        command || control || option || (key.hasPrefix("f") && Int(key.dropFirst()) != nil)
    }

    func with(key: String) -> Chord {
        var copy = self
        copy.key = key
        return copy
    }

    /// The same, for a menu item — nil for a key a menu can't show.
    var menu: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "tab": equivalent = .tab
        case "esc": equivalent = .escape
        case "return": equivalent = .return
        case "space": equivalent = .space
        case "delete": equivalent = .delete
        case "forwarddelete": equivalent = .deleteForward
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "home": equivalent = .home
        case "end": equivalent = .end
        case "pageup": equivalent = .pageUp
        case "pagedown": equivalent = .pageDown
        default:
            guard key.count == 1, let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

@MainActor
final class Keys: ObservableObject {
    enum Command: String, CaseIterable, Identifiable {
        case newTab, newPrivateTab, reopenTab, closeTab, closeOthers, duplicate, pinTab
        case address, switchTab, tabNumber, nextTab, previousTab, recentTab, recentTabBack
        case back, forward, reload, hardReload, findOnPage, findNext, findPrevious, print
        case copyAddress, pasteAndGo, bookmark, bookmarks, history, downloads, muteTab
        case readingMode, floatVideo, hideElements, hiddenHere, zoomIn, zoomOut, actualSize, inspector
        case sidebar, hideTabs, settings, passwords, welcome
        case profileNumber, previousProfile, nextProfile, newProfile

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newTab: return "New tab"
            case .newPrivateTab: return "New private tab"
            case .reopenTab: return "Reopen closed tab"
            case .closeTab: return "Close tab"
            case .closeOthers: return "Close other tabs"
            case .duplicate: return "Duplicate tab"
            case .pinTab: return "Pin or unpin the tab"
            case .address: return "Open address"
            case .switchTab: return "Search tabs"
            case .tabNumber: return "Go to tab 1 … 9"
            case .nextTab: return "Next tab"
            case .previousTab: return "Previous tab"
            case .recentTab: return "Last viewed tab"
            case .recentTabBack: return "Last viewed tab, the other way"
            case .back: return "Back"
            case .forward: return "Forward"
            case .reload: return "Reload"
            case .hardReload: return "Reload without the cache"
            case .findOnPage: return "Find on page"
            case .findNext: return "Find next"
            case .findPrevious: return "Find previous"
            case .print: return "Print"
            case .copyAddress: return "Copy address"
            case .pasteAndGo: return "Paste and go"
            case .bookmark: return "Bookmark this page"
            case .bookmarks: return "Show bookmarks"
            case .history: return "History"
            case .downloads: return "Downloads"
            case .muteTab: return "Stop sound in tab"
            case .readingMode: return "Reading mode"
            case .floatVideo: return "Float the video"
            case .hideElements: return "Hide something on this site"
            case .hiddenHere: return "What is hidden here"
            case .zoomIn: return "Zoom in"
            case .zoomOut: return "Zoom out"
            case .actualSize: return "Actual size"
            case .inspector: return "Web inspector"
            case .sidebar: return "Tabs in a sidebar"
            case .hideTabs: return "Hide or show the tabs"
            case .settings: return "Settings"
            case .passwords: return "Passwords"
            case .welcome: return "Welcome"
            case .profileNumber: return "Go to profile 1 … 9"
            case .previousProfile: return "Previous profile"
            case .nextProfile: return "Next profile"
            case .newProfile: return "New profile"
            }
        }

        /// The key it answers to until somebody changes it. Nil for one that
        /// waits to be given a key.
        var fallback: String? {
            switch self {
            case .newTab: return "cmd+t"
            case .newPrivateTab: return "shift+cmd+n"
            case .reopenTab: return "shift+cmd+t"
            case .closeTab: return "cmd+w"
            case .closeOthers: return nil
            case .duplicate: return "cmd+d"
            case .pinTab: return "shift+cmd+d"
            case .address: return "cmd+l"
            case .switchTab: return "cmd+k"
            case .tabNumber: return "cmd+1"
            case .nextTab: return "shift+cmd+]"
            case .previousTab: return "shift+cmd+["
            case .recentTab: return "ctrl+tab"
            case .recentTabBack: return "ctrl+shift+tab"
            case .back: return "cmd+["
            case .forward: return "cmd+]"
            case .reload: return "cmd+r"
            case .hardReload: return "shift+cmd+r"
            case .findOnPage: return "cmd+f"
            case .findNext: return "cmd+g"
            case .findPrevious: return "shift+cmd+g"
            case .print: return "cmd+p"
            case .copyAddress: return "shift+cmd+c"
            case .pasteAndGo: return "shift+cmd+v"
            case .bookmark: return "shift+cmd+b"
            case .bookmarks: return nil
            case .history: return "cmd+y"
            case .downloads: return "shift+cmd+j"
            case .muteTab: return "shift+cmd+m"
            case .readingMode: return nil
            case .floatVideo: return "shift+cmd+p"
            case .hideElements: return "shift+cmd+h"
            case .hiddenHere: return "shift+cmd+u"
            case .zoomIn: return "cmd+="
            case .zoomOut: return "cmd+-"
            case .actualSize: return "cmd+0"
            case .inspector: return "opt+cmd+i"
            case .sidebar: return "shift+cmd+s"
            case .hideTabs: return "opt+cmd+s"
            case .settings: return "cmd+,"
            case .passwords: return "opt+cmd+l"
            case .welcome: return nil
            case .profileNumber: return "ctrl+1"
            case .previousProfile: return "opt+cmd+["
            case .nextProfile: return "opt+cmd+]"
            case .newProfile: return nil
            }
        }

        /// What the settings page says under the two that stand for nine.
        var detail: String? {
            switch self {
            case .tabNumber: return "The same modifiers with 2 to 9; 9 is the last tab"
            case .profileNumber: return "The same modifiers with 2 to 9"
            default: return nil
            }
        }

        static let groups: [(String, [Command])] = [
            ("Tabs", [.newTab, .newPrivateTab, .closeTab, .reopenTab, .closeOthers, .duplicate, .pinTab, .muteTab]),
            ("Getting around", [.address, .switchTab, .tabNumber, .nextTab, .previousTab, .recentTab, .recentTabBack, .back, .forward]),
            ("The page", [.reload, .hardReload, .findOnPage, .findNext, .findPrevious, .readingMode, .floatVideo,
                          .hideElements, .hiddenHere, .zoomIn, .zoomOut, .actualSize, .print, .copyAddress, .pasteAndGo, .inspector]),
            ("Panels", [.bookmark, .bookmarks, .history, .downloads, .settings, .passwords, .welcome]),
            ("The window", [.sidebar, .hideTabs]),
            ("Profiles", [.profileNumber, .previousProfile, .nextProfile, .newProfile]),
        ]
    }

    /// A key of your own: it opens a page. Without a key until one is
    /// recorded for it.
    struct Custom: Identifiable, Equatable {
        let id: UUID
        var chord: Chord?
        var url: String
    }

    /// What the next key press is for, while one is being recorded.
    enum Target: Equatable {
        case command(Command)
        case custom(UUID)
    }

    @Published private(set) var chords: [Command: Chord] = [:]
    @Published private(set) var custom: [Custom] = []
    @Published var recording: Target?

    private var byChord: [Chord: Command] = [:]
    private let store = Store.settings
    private static let key = "keys"
    private static let customKey = "keys.custom"

    init() {
        let kept = store.dictionary(forKey: Keys.key) as? [String: String] ?? [:]
        for command in Command.allCases {
            // A command in the file is as the file says, "" for no key; one
            // not in the file is as it always was.
            let text = kept[command.rawValue] ?? command.fallback ?? ""
            if let chord = Chord(text) { chords[command] = chord }
        }
        custom = (store.array(forKey: Keys.customKey) as? [[String: String]] ?? []).map {
            Custom(id: UUID(uuidString: $0["id"] ?? "") ?? UUID(), chord: ($0["key"]).flatMap(Chord.init), url: $0["url"] ?? "")
        }
        index()
    }

    /// The two that stand for nine are not in the reverse map: their key is
    /// a pattern, matched on the digit by the key monitor, and finding the
    /// 1 here would answer it with nothing — ⌘1 did nothing for a day.
    private func index() {
        byChord = Dictionary(
            chords.filter { $0.key != .tabNumber && $0.key != .profileNumber }.map { ($0.value, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func save() {
        var kept: [String: String] = [:]
        for command in Command.allCases where chords[command]?.text != command.fallback {
            kept[command.rawValue] = chords[command]?.text ?? ""
        }
        store.set(kept, forKey: Keys.key)
        store.set(custom.map { ["id": $0.id.uuidString, "key": $0.chord?.text ?? "", "url": $0.url] }, forKey: Keys.customKey)
        index()
    }

    func chord(for command: Command) -> Chord? { chords[command] }
    func command(for chord: Chord) -> Command? { byChord[chord] }
    func custom(for chord: Chord) -> Custom? { custom.first { $0.chord == chord } }
    func menu(_ command: Command) -> KeyboardShortcut? { chords[command]?.menu }
    func menu(_ command: Command, digit: Int) -> KeyboardShortcut? { chords[command]?.with(key: "\(digit)").menu }
    func changed(_ command: Command) -> Bool { chords[command]?.text != command.fallback }

    /// One key, one thing: a key given to something is taken from whatever
    /// had it.
    func set(_ chord: Chord?, for command: Command) {
        if let chord { take(chord) }
        chords[command] = chord
        save()
    }

    func set(_ chord: Chord?, forCustom id: UUID) {
        guard let at = custom.firstIndex(where: { $0.id == id }) else { return }
        if let chord { take(chord) }
        custom[at].chord = chord
        save()
    }

    private func take(_ chord: Chord) {
        if let had = byChord[chord] { chords[had] = nil }
        for at in custom.indices where custom[at].chord == chord { custom[at].chord = nil }
    }

    func reset(_ command: Command) { set(command.fallback.flatMap(Chord.init), for: command) }

    func resetAll() {
        chords = [:]
        for command in Command.allCases {
            if let chord = command.fallback.flatMap(Chord.init) { chords[command] = chord }
        }
        save()
    }

    func addCustom(url: String) -> UUID {
        let entry = Custom(id: UUID(), chord: nil, url: url)
        custom.append(entry)
        save()
        return entry.id
    }

    func removeCustom(_ id: UUID) {
        custom.removeAll { $0.id == id }
        save()
    }

    /// A key press while recording: the answer, or esc to leave things as
    /// they were, or ⌫ for no key at all. Always taken — nothing else gets a
    /// key that was meant for here.
    func record(_ event: NSEvent) -> Bool {
        guard let target = recording else { return false }
        if event.keyCode == 53 {
            recording = nil
            return true
        }
        guard let chord = Chord(event: event) else { return true }
        let answer: Chord? = chord.key == "delete" && !chord.command && !chord.option && !chord.control ? nil : chord
        if let answer, !answer.usable { return true }
        switch target {
        case .command(let command): set(answer, for: command)
        case .custom(let id): set(answer, forCustom: id)
        }
        recording = nil
        return true
    }
}

// MARK: - the settings page

/// Every command with its key, each key changeable: press Change, then the
/// keys. Below them, keys of your own that open a page.
struct ShortcutsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var keys: Keys

    var body: some View {
        Caption("Press Change, then the keys. ⌫ leaves a command with no key; esc keeps what it had. A key given to one thing is taken from another.")
        ForEach(Keys.Command.groups, id: \.0) { title, commands in
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 2)
                Card {
                    ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                        if index > 0 { Rule() }
                        Line(command.title, command.detail) {
                            control(for: .command(command), chord: keys.chord(for: command), changed: keys.changed(command)) {
                                keys.reset(command)
                            }
                        }
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Your own")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 2)
            Card {
                ForEach(keys.custom) { entry in
                    Line(entry.url, "Opens it in the tab you are on") {
                        HStack(spacing: 6) {
                            control(for: .custom(entry.id), chord: entry.chord, changed: false) {}
                            Pill("Remove") { keys.removeCustom(entry.id) }
                        }
                    }
                    Rule()
                }
                Line("A key of your own", "Opens a page: an address, or words to search for") {
                    Pill("Add…", filled: true) { browser.addCustomKey() }
                }
            }
        }
        HStack {
            Spacer()
            Pill("Reset all to how they were") { keys.resetAll() }
        }
    }

    /// The key as it is, and the pill that changes it — or, while it is
    /// being recorded, the word that says so.
    private func control(for target: Keys.Target, chord: Chord?, changed: Bool, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if keys.recording == target {
                Text("Press keys…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Pill("Cancel") { keys.recording = nil }
            } else {
                Text(chord?.label ?? "None")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(chord == nil ? Palette.muted : Palette.ink)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.wash.opacity(chord == nil ? 0.3 : 0.7))
                    )
                Pill("Change") { keys.recording = target }
                if changed {
                    Pill("Reset", action: reset)
                }
            }
        }
    }
}

extension Browser {
    /// A page for a key of your own, asked for in a sheet; then the key.
    func addCustomKey() {
        askProfileName("A page to open — an address, or words to search for") { [weak self] text in
            guard let self else { return }
            let id = keys.addCustom(url: text)
            keys.recording = .custom(id)
        }
    }
}
