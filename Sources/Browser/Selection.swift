import AppKit

// Several tabs at once. ⌘-click picks a tab out, or puts it back; ⇧-click
// picks out the run from the last one picked to this one; a plain click on
// any tab, or esc, lets them all go. The tab on screen counts as picked from
// the first ⌘- or ⇧-click, as it does in every browser, and no click with a
// key held ever visits a tab. A right-click on any picked tab offers what can
// be done with the lot — to another profile, to a new one, or closed — and
// ⌘W with several picked closes them all. The state is in Browser.swift with
// the tabs; the moving is beside the profiles there.

extension Browser {
    /// A click on a tab with ⌘ or ⇧ held. True when it was a choice and the
    /// tab is not to be visited; false when no key was held and the click is
    /// the caller's as before. The flags are the event's own, so a click a
    /// script posts with ⌘ in it counts as much as a hand's.
    func choose(_ tab: Tab, with flags: NSEvent.ModifierFlags? = nil) -> Bool {
        let held = (flags ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
            .intersection([.command, .shift])
        guard !held.isEmpty else { return false }
        if chosen.isEmpty, let active, active.id != tab.id {
            chosen = [active.id]
            choiceAnchor = active.id
        }
        if held.contains(.shift) {
            let from = choiceAnchor.flatMap { id in tabs.firstIndex { $0.id == id } }
                ?? tabs.firstIndex { $0.id == activeID } ?? 0
            if let to = tabs.firstIndex(where: { $0.id == tab.id }) {
                for one in tabs[min(from, to)...max(from, to)] { chosen.insert(one.id) }
            }
        } else if chosen.contains(tab.id) {
            chosen.remove(tab.id)
            choiceAnchor = chosen.isEmpty ? nil : tab.id
        } else {
            chosen.insert(tab.id)
            choiceAnchor = tab.id
        }
        if chosen.count < 2 { unchoose() }
        return true
    }

    func unchoose() {
        if !chosen.isEmpty { chosen = [] }
        choiceAnchor = nil
    }

    /// The picked tabs, in the order of the row.
    var chosenTabs: [Tab] { tabs.filter { chosen.contains($0.id) } }

    /// ⌘W: the picked tabs together, or the one on screen.
    func closeCommand() {
        if chosen.count > 1 {
            closeChosen()
        } else if let active {
            close(active)
        }
    }

    func closeChosen() {
        let list = chosenTabs
        unchoose()
        for tab in list { close(tab) }
    }

    func moveChosen(toProfile index: Int) {
        let list = chosenTabs
        unchoose()
        move(list, toProfile: index)
    }

    /// A name asked for, the profile made, the tabs moved into it — and
    /// straight into it, as a new profile always goes.
    /// One tab into a profile made for it, and straight into that profile.
    func moveToNewProfile(_ tab: Tab) {
        askProfileName("New profile from this tab") { [weak self] name in
            guard let self else { return }
            let index = makeProfile(named: name)
            move([tab], toProfile: index)
            switchProfile(to: index)
        }
    }

    func moveChosenToNewProfile() {
        let list = chosenTabs
        guard !list.isEmpty else { return }
        unchoose()
        askProfileName(list.count == 1 ? "New profile from this tab" : "New profile from \(list.count) tabs") { [weak self] name in
            guard let self else { return }
            let index = makeProfile(named: name)
            move(list, toProfile: index)
            switchProfile(to: index)
        }
    }
}
