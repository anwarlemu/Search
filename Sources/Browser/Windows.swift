import AppKit
import WebKit

// The small things Safari, Chrome and Arc do with windows, links and the
// buttons beside the tabs, now that a tab can have a window of its own
// (15 Oct 2026).

extension Browser {
    /// A new window's frame: the size of this one, a step down and across,
    /// the way a Mac cascades them.
    private var cascade: NSRect {
        let was = window?.frame ?? NSRect(x: 200, y: 200, width: 1180, height: 780)
        return was.offsetBy(dx: 28, dy: -28)
    }

    /// ⌘N. A window with one empty tab, ready for an address.
    func newWindow() {
        guard let open = Browser.openTorn else { return }
        let tab = Tab()
        var handoff = Handoff(tab: tab, frame: cascade)
        handoff.space = isPrivate ? nil : profile
        Browser.handoffs[tab.id] = handoff
        open(tab.id)
    }

    /// ⇧-click on a link, or Open Link in New Window: the page in a window
    /// of its own, in front.
    func openInNewWindow(_ url: URL) {
        guard !isPrivate, let open = Browser.openTorn else {
            _ = self.open(url, foreground: true)
            return
        }
        let tab = Tab(configuration: Browser.extensionConfiguration(for: url))
        tab.go(to: Browser.page(url))
        var handoff = Handoff(tab: tab, frame: cascade)
        handoff.space = profile
        Browser.handoffs[tab.id] = handoff
        open(tab.id)
    }

    /// The tab's menu: Move to New Window. Where tearing it off would have
    /// put it, but a step from this window rather than under a pointer.
    func moveToNewWindow(_ tab: Tab) {
        tearOff(tab, at: .zero, frame: cascade)
    }

    /// Window › Merge All Windows: every torn window's tabs into this one,
    /// after its own, and those windows gone.
    func mergeAllWindows() {
        guard !isPrivate, let home = window else { return }
        let bottom = NSPoint(x: home.frame.minX + 60, y: home.frame.minY + 4)
        for other in Browser.every.allObjects where other !== self && other.isTorn {
            // Its own tabs. Its pins are this window's already, or another
            // space's — every window has those.
            for tab in other.tabs where tab.pin == nil {
                other.give(tab, to: self, at: bottom)
            }
            other.window?.close()
        }
        Browser.bringForward(home)
    }

    /// Every tab after this one, pins left alone — the column's "below",
    /// the strip's "to the right".
    func closeAfter(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let going = tabs[(index + 1)...].filter { $0.pin == nil }
        guard !going.isEmpty else { return }
        if let active, going.contains(where: { $0.id == active.id }) { select(tab) }
        for one in going { close(one) }
    }

    /// The pages behind the active one, nearest first — or ahead of it —
    /// for the menu that hangs from the back and forward buttons.
    func history(back: Bool) -> [WKBackForwardListItem] {
        guard let list = active?.built?.backForwardList else { return [] }
        return back ? list.backList.reversed() : list.forwardList
    }

    /// One of those pages: here, or with ⌘ or the middle button, in a tab
    /// beside this one.
    func go(to item: WKBackForwardListItem, beside: Bool) {
        if beside {
            _ = open(item.url, foreground: NSEvent.modifierFlags.contains(.shift))
        } else {
            active?.built?.go(to: item)
        }
    }

    /// Back or forward, as the click asks: ⌘-click opens it beside.
    func step(back: Bool) {
        let beside = NSEvent.modifierFlags.contains(.command) || NSApp.currentEvent?.type == .otherMouseUp
        if beside, let item = history(back: back).first {
            go(to: item, beside: true)
        } else if back {
            self.back()
        } else {
            forward()
        }
    }

    /// The reload button, as the click asks: ⇧ or ⌥ leaves the cache out,
    /// as in Chrome and Safari.
    func reloadClicked() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) || flags.contains(.option) { hardReload() } else { reload() }
    }

    /// A press and hold on back or forward: the pages that way, as a menu
    /// under the pointer.
    func showHistory(back: Bool) {
        let items = history(back: back)
        guard !items.isEmpty else { return }
        let menu = NSMenu()
        for item in items.prefix(20) {
            let title = item.title?.isEmpty == false ? item.title! : Address.pretty(item.url)
            let entry = NSMenuItem(title: title, action: #selector(MenuHand.fire(_:)), keyEquivalent: "")
            let hand = MenuHand { [weak self] in self?.go(to: item, beside: false) }
            entry.target = hand
            entry.representedObject = hand
            if let icon = Favicons.shared.cached(item.url.host()?.lowercased() ?? "")?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item's action as a closure. The item keeps it alive.
final class MenuHand: NSObject {
    let act: () -> Void
    init(_ act: @escaping () -> Void) { self.act = act }
    @objc func fire(_ sender: Any?) { act() }
}
