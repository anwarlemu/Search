import Foundation

// Where you have been, so the field can finish the address for you. Kept in one
// small file next to the app's own settings, written a moment after a visit
// rather than on every keystroke.

struct Suggestion: Identifiable, Equatable {
    /// What you would have typed to get here: no scheme, no www.
    let key: String
    let title: String
    let url: URL
    let kind: Kind
    /// Set when this is a page you already have open somewhere.
    var tab: UUID?
    /// The heading this row sits under, on an empty tab's list — see
    /// Fresh.swift. Rows with none are the field's ordinary answers.
    var section: String? = nil
    /// A second line's worth, grey: when a meeting is, which calendar.
    var detail: String? = nil
    /// What Return does here, shown at the row's end: "Join ⏎".
    var hint: String? = nil

    enum Kind {
        /// A page that is open right now.
        case open
        /// Somewhere you have actually been.
        case visited
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all — words, and an engine to ask.
        case search
        /// On an empty tab: a meeting from the calendar, a page you were
        /// just on, one you keep going back to, a place to make something.
        case meeting, recent, frequent, action
    }

    var id: String { "\(kind)|\(section ?? "")|\(tab?.uuidString ?? Address.identity(url))" }
}

private struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
    // Optional so the original history file still decodes.
    var inferred: Bool?
}

@MainActor
final class History: ObservableObject {
    nonisolated static let limit = 2_000
    private var visits: [String: Visit] = [:]
    private let file: URL
    private let capacity: Int
    private var saving = false
    private var batching = false
    private var batchChanged = false
    private static let writer = DispatchQueue(label: "browser.history", qos: .utility)

    /// URL parsing, searchable text and chronological ordering are rebuilt
    /// once per change, rather than on each keystroke or menu redraw.
    private struct Indexed {
        let visit: Visit
        let trace: Trace
        let search: String
        let address: String
    }
    private var cached: [Indexed]?

    init(file: URL? = nil, capacity: Int = History.limit) {
        self.file = file ?? Store.file("history.json")
        self.capacity = max(1, capacity)
        load()
    }

    struct Trace: Identifiable, Equatable {
        /// Canonical URL, separate from the compact label shown to a person.
        let key: String
        let title: String
        let url: URL
        let last: Date
        let count: Int
        var id: String { key }
        var label: String { Address.pretty(url) }
    }

    private var indexed: [Indexed] {
        if let cached { return cached }
        let rows = visits.compactMap { key, visit -> Indexed? in
            guard let url = URL(string: visit.url) else { return nil }
            let label = Address.pretty(url)
            return Indexed(visit: visit,
                trace: Trace(key: key, title: visit.title, url: url, last: visit.last, count: visit.count),
                search: (label + " " + visit.title).lowercased(), address: label.lowercased())
        }.sorted { $0.visit.last == $1.visit.last ? $0.trace.key < $1.trace.key : $0.visit.last > $1.visit.last }
        cached = rows
        return rows
    }

    func recent(_ count: Int) -> [Trace] {
        Array(indexed.lazy.filter { $0.visit.inferred != true }.prefix(max(0, count)).map(\.trace))
    }

    func everything(matching typed: String = "") -> [Trace] {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return indexed.filter { $0.visit.inferred != true && (needle.isEmpty || $0.search.contains(needle)) }.map(\.trace)
    }

    func record(_ url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let home = Address.home(url), Address.identity(home) != Address.identity(url) {
            merge(home, title: "", count: 1, last: Date(), inferred: true)
        }
        merge(url, title: title, count: 1, last: Date(), inferred: false)
        changed()
        save()
    }

    func take(_ url: URL, title: String, count: Int, last: Date) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        merge(url, title: title, count: count, last: last, inferred: false)
        changed()
    }

    /// Imports publish once, after merging and applying the live-memory cap.
    func batch(_ work: () -> Void) {
        guard !batching else { work(); return }
        batching = true
        work()
        batching = false
        if batchChanged { batchChanged = false; changed() }
    }

    func settle() { save() }

    private func merge(_ url: URL, title: String, count: Int, last: Date, inferred: Bool) {
        let key = Address.identity(url)
        if var seen = visits[key] {
            seen.count = min(1_000_000, seen.count + max(0, min(count, 1_000_000)))
            if last >= seen.last {
                seen.last = last
                if !title.isEmpty { seen.title = title }
            } else if seen.title.isEmpty { seen.title = title }
            if !inferred { seen.inferred = false }
            visits[key] = seen
        } else {
            visits[key] = Visit(url: url.absoluteString, key: Address.pretty(url), title: title,
                count: max(0, min(count, 1_000_000)), last: last, inferred: inferred)
        }
    }

    func retitle(_ url: URL, _ title: String) {
        let key = Address.identity(url)
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        changed()
        save()
    }

    func forget() {
        visits.removeAll()
        changed()
        save()
    }

    func forget(_ key: String) {
        guard visits.removeValue(forKey: key) != nil else { return }
        changed()
        save()
    }

    private func changed() {
        cached = nil
        if batching { batchChanged = true; return }
        trim()
        objectWillChange.send()
    }

    private func trim() {
        guard visits.count > capacity else { return }
        let now = Date()
        // Score each entry once; comparisons do no date math or exponentials.
        var ranked: [(key: String, score: Double)] = visits.map { key, visit in
            (key: key, score: frecency(visit, now: now))
        }
        ranked.sort { left, right in
            if left.score == right.score { return left.key < right.key }
            return left.score > right.score
        }
        for row in ranked.dropFirst(capacity) { visits.removeValue(forKey: row.key) }
    }

    func suggestions(for typed: String, limit: Int = 5) -> [Suggestion] {
        let needle = strip(typed)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let now = Date()
        var best: [(row: Suggestion, score: Double)] = []
        func offer(_ row: Suggestion, _ score: Double) {
            let at = best.firstIndex { other in
                if score != other.score { return score > other.score }
                if row.key.count != other.row.key.count { return row.key.count < other.row.key.count }
                return row.id < other.row.id
            } ?? best.count
            guard at < limit else { return }
            best.insert((row, score), at: at)
            if best.count > limit { best.removeLast() }
        }
        for entry in indexed {
            guard let rank = rank(entry.address, against: needle) else { continue }
            offer(Suggestion(key: entry.trace.label, title: entry.trace.title, url: entry.trace.url, kind: .visited),
                rank + 4 + frecency(entry.visit, now: now) + (entry.address.contains("/") ? 0 : 1.5))
        }
        for known in History.known {
            guard let url = URL(string: "https://" + known.0 + "/"), visits[Address.identity(url)] == nil,
                  let rank = rank(known.0, against: needle) else { continue }
            offer(Suggestion(key: known.0, title: known.1, url: url, kind: .known), rank)
        }
        return best.map(\.row)
    }

    /// Complete only a spelling that round-trips to the offered destination.
    /// In particular, a label for an HTTP site must not silently become HTTPS.
    func completion(for typed: String, among options: [Suggestion]) -> String? {
        guard typed.count >= 2 else { return nil }
        let lower = typed.lowercased()
        for hit in options where hit.kind != .search {
            let candidate = typed.contains("://") ? Address.editable(hit.url) : hit.key
            guard candidate.lowercased().hasPrefix(lower) else { continue }
            let rest = String(candidate.dropFirst(typed.count))
            guard !rest.isEmpty, let completed = Address.url(from: typed + rest),
                  Address.identity(completed) == Address.identity(hit.url) else { continue }
            return rest
        }
        return nil
    }

    private func rank(_ key: String, against needle: String) -> Double? {
        if key.hasPrefix(needle) { return 6 }
        let host = key.split(separator: "/").first.map(String.init) ?? key
        if let dot = host.range(of: "."), host[dot.upperBound...].hasPrefix(needle) { return 3 }
        if needle.count >= 2, host.contains(needle) { return 2 }
        return nil
    }

    private func frecency(_ visit: Visit, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
        return Double(visit.count) * exp(-days / 30)
    }

    private func strip(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            Store.quarantine(file)
            return
        }
        // Migrate using each saved URL, never the former lossy display key.
        // Duplicate records merge rather than crashing Dictionary's initializer.
        for visit in list {
            guard let url = URL(string: visit.url), ["http", "https"].contains(url.scheme ?? "") else { continue }
            let inferred = visit.inferred ?? (visit.title.isEmpty && !visit.key.contains("/"))
            merge(url, title: visit.title, count: visit.count, last: visit.last, inferred: inferred)
        }
        trim()
    }

    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.saving = false
            let list = Array(self.visits.values)
            let file = self.file
            Self.writer.async {
                guard let data = try? JSONEncoder().encode(list) else { return }
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// Somewhere to start on the first day, before there is any history to go
    /// on. Ranked below anything actually visited, and dropped from the list
    /// the moment you have been there yourself.
    private static let known: [(String, String)] = [
        ("google.com", "Google"), ("mail.google.com", "Gmail"),
        ("drive.google.com", "Google Drive"), ("calendar.google.com", "Google Calendar"),
        ("maps.google.com", "Google Maps"), ("youtube.com", "YouTube"),
        ("github.com", "GitHub"), ("figma.com", "Figma"), ("vercel.com", "Vercel"),
        ("notion.so", "Notion"), ("linear.app", "Linear"), ("slack.com", "Slack"),
        ("discord.com", "Discord"), ("x.com", "X"), ("linkedin.com", "LinkedIn"),
        ("instagram.com", "Instagram"), ("reddit.com", "Reddit"),
        ("news.ycombinator.com", "Hacker News"), ("stackoverflow.com", "Stack Overflow"),
        ("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"),
        ("dribbble.com", "Dribbble"), ("behance.net", "Behance"),
        ("awwwards.com", "Awwwards"), ("mobbin.com", "Mobbin"),
        ("siteinspire.com", "SiteInspire"), ("are.na", "Are.na"),
        ("pinterest.com", "Pinterest"), ("framer.com", "Framer"),
        ("webflow.com", "Webflow"), ("developer.apple.com", "Apple Developer"),
        ("swift.org", "Swift"), ("npmjs.com", "npm"), ("supabase.com", "Supabase"),
        ("stripe.com", "Stripe"), ("shopify.com", "Shopify"),
        ("cloudflare.com", "Cloudflare"), ("netlify.com", "Netlify"),
        ("apple.com", "Apple"), ("spotify.com", "Spotify"), ("netflix.com", "Netflix"),
        ("wikipedia.org", "Wikipedia"), ("deepl.com", "DeepL"), ("loom.com", "Loom"),
        ("amazon.fr", "Amazon"), ("leboncoin.fr", "leboncoin"), ("lemonde.fr", "Le Monde"),
    ]
}
