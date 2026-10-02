import AppKit

// An empty tab, before anything is typed: not a blank, but the few things
// that help you get moving. A meeting about to start, with the way in. The
// pages you were just on. The ones you keep going back to. A couple of
// places to make something new. Small and specific, in sections the field
// draws over its list — never a feed. The moment you type, it is the
// address field again and all of this gives way.

extension Browser {
    /// A word and an address each: somewhere to make a thing.
    static let actions: [(title: String, key: String, symbol: String)] = [
        ("New document", "docs.new", "doc.text"),
        ("New sheet", "sheets.new", "tablecells"),
        ("New meeting", "meet.new", "video"),
    ]

    func fresh() -> [Suggestion] {
        var list: [Suggestion] = []

        if prefs.agenda {
            for meeting in Agenda.shared.upcoming() {
                // Without a link the row still says what is next; Return
                // opens it in Calendar instead.
                let url = meeting.link
                    ?? URL(string: "calshow:\(Int(meeting.start.timeIntervalSinceReferenceDate))")
                    ?? URL(string: "calshow:")!
                list.append(Suggestion(
                    key: "meeting:" + meeting.id, title: meeting.title, url: url, kind: .meeting,
                    section: "Now",
                    detail: Agenda.phrase(for: meeting) + " · " + meeting.calendar,
                    hint: meeting.link == nil ? "Open ⏎" : "Join ⏎"
                ))
            }
        }

        // Where you were, leaving out what is open already — a tab you have
        // is a ⌘K away, not a thing to open twice.
        let open = Set(tabs.compactMap { $0.address.map { Address.pretty($0).lowercased() } })
        let everything = history.everything()
        var used = Set<String>()
        for trace in everything.filter({ !open.contains($0.key) }).prefix(3) {
            used.insert(trace.key)
            list.append(Suggestion(
                key: trace.key, title: trace.title, url: trace.url, kind: .recent, section: "Recent"
            ))
        }
        let frequent = everything
            .filter { !open.contains($0.key) && !used.contains($0.key) && $0.count >= 3 }
            .sorted { $0.count > $1.count }
            .prefix(3)
        for trace in frequent {
            list.append(Suggestion(
                key: trace.key, title: trace.title, url: trace.url, kind: .frequent, section: "Frequent"
            ))
        }

        for action in Browser.actions {
            guard let url = URL(string: "https://" + action.key) else { continue }
            list.append(Suggestion(
                key: action.key, title: action.title, url: url, kind: .action, section: "Quick actions"
            ))
        }
        return list
    }

    /// A row of the list, taken: a meeting's link is a page like any
    /// other; a meeting without one opens in Calendar.
    func go(to offer: Suggestion) {
        if offer.kind == .meeting, offer.url.scheme?.hasPrefix("http") != true {
            NSWorkspace.shared.open(offer.url)
            return
        }
        (active ?? tabs.first)?.go(to: offer.url)
    }
}
