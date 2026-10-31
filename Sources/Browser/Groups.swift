import SwiftUI

// Tab groups. Pick tabs out with ⌘- or ⇧-click, right-click, Group: they
// gather under a head that folds them away and opens them again with a
// click. The head is picked up with its tabs and put down whole; a tab
// dragged under a head joins it, one dragged out leaves it. Ungroup lets
// the head go and leaves every tab where it was.
//
// The row stays one flat list of tabs. A tab names its group, the browser
// keeps each group's name and fold, and what the row and the column draw —
// heads and tabs, in order — is worked out from the two (31 Oct 2026).

struct TabGroup: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var folded = false
}

/// One place among the loose tabs, as the row and the column draw them.
enum Slot: Identifiable {
    case head(TabGroup)
    case tab(Tab)

    var id: AnyHashable {
        switch self {
        case .head(let group): return "group-" + group.id.uuidString
        case .tab(let tab): return tab.id
        }
    }

    var tab: Tab? { if case .tab(let tab) = self { return tab }; return nil }
    var head: TabGroup? { if case .head(let group) = self { return group }; return nil }
}

extension Browser {
    func group(of tab: Tab) -> TabGroup? {
        guard tab.pin == nil, let id = tab.group else { return nil }
        return groups[id]
    }

    /// The loose tabs as drawn: each group's head where its first tab is,
    /// then its tabs — or, folded, only the one on screen if it is one of
    /// them. A group's tabs are drawn together even if a link opened among
    /// them for a moment put one apart.
    var slots: [Slot] {
        let loose = tabs.filter { $0.pin == nil }
        var out: [Slot] = []
        var done = Set<UUID>()
        for tab in loose {
            guard let kept = group(of: tab) else {
                out.append(.tab(tab))
                continue
            }
            guard done.insert(kept.id).inserted else { continue }
            out.append(.head(kept))
            for member in loose where member.group == kept.id && (!kept.folded || member.id == activeID) {
                out.append(.tab(member))
            }
        }
        return out
    }

    /// The groups in this window, in the order they are drawn.
    var groupsShown: [TabGroup] { slots.compactMap(\.head) }

    func members(of group: TabGroup) -> [Tab] {
        tabs.filter { $0.pin == nil && $0.group == group.id }
    }

    /// How many places a head takes when picked up: itself and its tabs.
    static func span(of group: TabGroup, at start: Int, in slots: [Slot]) -> Int {
        var end = start + 1
        while end < slots.count, let tab = slots[end].tab, tab.group == group.id { end += 1 }
        return end - start
    }

    /// The loose tabs in the order a list of slots puts them: a folded
    /// group's hidden tabs go where its head is.
    func order(of list: [Slot]) -> [Tab] {
        let shown = Set(list.compactMap { $0.tab?.id })
        var out: [Tab] = []
        var seen = Set<Tab.ID>()
        for slot in list {
            switch slot {
            case .tab(let tab):
                if seen.insert(tab.id).inserted { out.append(tab) }
            case .head(let group):
                for member in members(of: group) where !shown.contains(member.id) && seen.insert(member.id).inserted {
                    out.append(member)
                }
            }
        }
        // Nothing is ever lost to a list that missed it.
        for tab in tabs where tab.pin == nil && !seen.contains(tab.id) { out.append(tab) }
        return out
    }

    // MARK: - moving

    /// A loose tab let go of at `index` among the slots, counted without it.
    /// Under a head, or between two of a group's tabs, it joins that group;
    /// just past a group's last tab it stays in only if it was in already.
    func place(_ tab: Tab, at index: Int) {
        var list = slots.filter { $0.tab !== tab }
        let at = min(max(0, index), list.count)
        let before = at > 0 ? list[at - 1] : nil
        let after = at < list.count ? list[at].tab.flatMap(group(of:))?.id : nil
        var joins: UUID?
        switch before {
        case .head(let group)?:
            joins = !group.folded || after == group.id ? group.id : nil
        case .tab(let above)?:
            if let id = group(of: above)?.id, after == id || tab.group == id { joins = id }
        case nil:
            joins = nil
        }
        list.insert(.tab(tab), at: at)
        objectWillChange.send()
        tab.group = joins
        arrange(order(of: list))
    }

    /// Where a picked-up group may land nearest `index`, counted among the
    /// slots without it: never inside another group.
    func landing(of group: TabGroup, near index: Int) -> Int {
        let list = slots.filter { $0.head?.id != group.id && $0.tab?.group != group.id }
        let open = (0...list.count).filter { at in
            at == list.count || list[at].tab.flatMap(self.group(of:)) == nil
        }
        return open.min { abs($0 - index) < abs($1 - index) } ?? list.count
    }

    /// A head let go of at `index` among the slots without its group.
    func place(_ group: TabGroup, at index: Int) {
        let all = slots
        guard let start = all.firstIndex(where: { $0.head?.id == group.id }) else { return }
        let span = Browser.span(of: group, at: start, in: all)
        var list = all
        let block = Array(list[start..<start + span])
        list.removeSubrange(start..<start + span)
        list.insert(contentsOf: block, at: min(landing(of: group, near: index), list.count))
        arrange(order(of: list))
    }

    // MARK: - making and unmaking

    /// The picked tabs, gathered where the first of them was. Pins stay pins.
    func groupChosen() {
        let list = chosenTabs.filter { $0.pin == nil }
        unchoose()
        makeGroup(of: list)
    }

    func makeGroup(of list: [Tab]) {
        guard !list.isEmpty else { return }
        let group = TabGroup(id: UUID(), name: "")
        objectWillChange.send()
        groups[group.id] = group
        gather(list, into: group)
        // Named straight away, in place; enter or a click elsewhere keeps it.
        editingGroup = group.id
    }

    func add(_ list: [Tab], to group: TabGroup) {
        let list = list.filter { $0.pin == nil && $0.group != group.id }
        guard !list.isEmpty else { return }
        objectWillChange.send()
        gather(list, into: group)
    }

    func addChosen(to group: TabGroup) {
        let list = chosenTabs
        unchoose()
        add(list, to: group)
    }

    /// The tabs into the group, after its last tab — or, for a new group,
    /// where the first of them is.
    private func gather(_ list: [Tab], into group: TabGroup) {
        let ids = Set(list.map(\.id))
        var loose = tabs.filter { $0.pin == nil }
        let anchor = loose.lastIndex { $0.group == group.id && !ids.contains($0.id) }
        let first = anchor.map { $0 + 1 } ?? loose.firstIndex { ids.contains($0.id) } ?? loose.count
        let ahead = loose.prefix(first).filter { ids.contains($0.id) }.count
        loose.removeAll { ids.contains($0.id) }
        for tab in list { tab.group = group.id }
        loose.insert(contentsOf: tabs.filter { ids.contains($0.id) }, at: min(first - ahead, loose.count))
        arrange(loose)
    }

    /// Out of its group, to just past the group's last tab.
    func removeFromGroup(_ tab: Tab) {
        guard let id = tab.group else { return }
        var loose = tabs.filter { $0.pin == nil && $0.id != tab.id }
        let at = (loose.lastIndex { $0.group == id } ?? loose.count - 1) + 1
        objectWillChange.send()
        tab.group = nil
        loose.insert(tab, at: min(at, loose.count))
        arrange(loose)
    }

    /// The head goes; every tab stays where it was.
    func ungroup(_ group: TabGroup) {
        objectWillChange.send()
        for tab in tabs where tab.group == group.id { tab.group = nil }
        groups[group.id] = nil
        if editingGroup == group.id { editingGroup = nil }
        rememberSession()
    }

    func closeGroup(_ group: TabGroup) {
        let list = members(of: group)
        groups[group.id] = nil
        if editingGroup == group.id { editingGroup = nil }
        for tab in list { close(tab) }
        rememberSession()
    }

    /// A click on the head. Folding away the group the page on screen is
    /// in steps off it first, to the nearest tab outside — as Chrome does —
    /// so folding it is never undone by the one tab it can't hide.
    func fold(_ group: TabGroup) {
        guard var it = groups[group.id] else { return }
        it.folded.toggle()
        if it.folded, let active, active.pin == nil, active.group == group.id,
           let here = tabs.firstIndex(where: { $0.id == active.id }) {
            let outside = { (tab: Tab) in tab.group != group.id || tab.pin != nil }
            if let next = tabs[here...].first(where: outside) ?? tabs[..<here].last(where: outside) {
                select(next)
            }
        }
        groups[group.id] = it
        rememberSession()
    }

    func rename(_ group: TabGroup, to name: String) {
        guard groups[group.id] != nil else { return }
        groups[group.id]?.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func endGroupEdit() {
        guard editingGroup != nil else { return }
        editingGroup = nil
        rememberSession()
    }
}

// MARK: - the head

/// A group's head: a chevron, its name, and how many it holds while folded.
/// A click folds or opens it; the menu renames it or lets it go. The same
/// head in the column and, as wide as a tab, in the strip.
struct GroupHead: View, Equatable {
    let browser: Browser
    let group: TabGroup
    let count: Int
    let naming: Bool
    var height: CGFloat = 28
    var width: CGFloat? = nil

    static func == (a: GroupHead, b: GroupHead) -> Bool {
        a.browser === b.browser && a.group == b.group && a.count == b.count && a.naming == b.naming
            && a.height == b.height && a.width == b.width
    }

    @State private var hovering = false

    /// Down to a tab's mark, the strip's head has room for the chevron alone.
    private var bare: Bool { (width ?? .infinity) < Metrics.tabTitled }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(group.folded ? 0 : 90))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .frame(width: 16)
            if naming {
                GroupField(browser: browser, group: group)
                    .frame(height: 16)
            } else if !bare {
                Text(group.name.isEmpty ? "Untitled" : group.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(group.name.isEmpty ? Palette.muted.opacity(0.7) : Palette.muted)
            }
            Spacer(minLength: 0)
            if group.folded, !naming, !bare {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading, bare ? 0 : 11)
        .padding(.trailing, bare ? 0 : 11)
        .frame(width: width, height: height, alignment: bare ? .center : .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering && !naming ? Palette.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { if !naming { browser.fold(group) } }
        .onHover { hovering = $0 }
        .contextMenu { GroupMenu(browser: browser, group: group) }
        .help(bare ? (group.name.isEmpty ? "Untitled group" : group.name) : "")
        .animation(Motion.quick, value: hovering)
        .transition(.opacity)
    }
}

/// Right-click on a head.
struct GroupMenu: View {
    @ObservedObject var browser: Browser
    let group: TabGroup

    var body: some View {
        Button("Rename Group") { browser.editingGroup = group.id }
        Button(group.folded ? "Expand Group" : "Collapse Group") { browser.fold(group) }
        Button("New Tab in Group") {
            browser.newTab()
            if let tab = browser.active, tab.pin == nil { browser.add([tab], to: group) }
            if group.folded { browser.fold(group) }
        }
        Divider()
        // The group goes, its tabs stay.
        Button("Ungroup") { browser.ungroup(group) }
        Button("Close Group") { browser.closeGroup(group) }
    }
}

/// The group's name, typed in its head. Arrives selected, so typing
/// replaces it; enter, esc, tab or a click elsewhere keeps what is there.
struct GroupField: NSViewRepresentable {
    let browser: Browser
    let group: TabGroup

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, group: group) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5, weight: .medium)
        field.textColor = Palette.NS.ink
        field.placeholderString = "Name this group"
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = group.name
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.group = group
        // The field is only here while typing: what it holds is the truth.
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var group: TabGroup
        var claimed = false

        init(browser: Browser, group: TabGroup) {
            self.browser = browser
            self.group = group
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            browser.rename(group, to: field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endGroupEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endGroupEdit() }
        }
    }
}
