import EventKit
import Foundation

// What is next on your calendar, for the top of an empty tab: a meeting
// under way or about to start, and the way into it when the invitation
// holds a link. Asked of macOS once, from Settings › General; nothing is
// read until you turn it on, and nothing leaves the Mac.

@MainActor
final class Agenda {
    static let shared = Agenda()
    private let store = EKEventStore()

    struct Meeting: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        /// Where the call is, when the invitation says.
        let link: URL?
        let calendar: String
    }

    var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func ask(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Meetings under way or starting within `hours`, soonest first. Not
    /// the all-day ones: a birthday is not something to join.
    func upcoming(hours: Double = 2, limit: Int = 3) -> [Meeting] {
        guard allowed else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-5 * 60),
            end: now.addingTimeInterval(hours * 3600),
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map {
                Meeting(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: ($0.title ?? "").isEmpty ? "Meeting" : $0.title,
                    start: $0.startDate, end: $0.endDate,
                    link: Agenda.link(in: $0),
                    calendar: $0.calendar.title
                )
            }
    }

    /// The places calls happen. A link to one of these in the invitation's
    /// address, place or notes is the way in; failing that, whatever
    /// address the invitation carries.
    private static let rooms = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "whereby.com",
        "webex.com", "gotomeeting.com", "around.co", "meet.jit.si", "tuple.app", "discord.gg",
        "slack.com/huddle", "cal.com/video", "facetime.apple.com",
    ]

    static func link(in event: EKEvent) -> URL? {
        var found: [URL] = []
        if let url = event.url { found.append(url) }
        let pattern = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#)
        for text in [event.location, event.notes].compactMap({ $0 }) {
            pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)).forEach { match in
                if let range = Range(match.range, in: text), let url = URL(string: String(text[range])) {
                    found.append(url)
                }
            }
        }
        return found.first { url in rooms.contains { url.absoluteString.contains($0) } }
            ?? event.url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
    }

    /// "in 9m", "now · 23m left", "in 1h 5m".
    static func phrase(for meeting: Meeting, at now: Date = Date()) -> String {
        func span(_ seconds: TimeInterval) -> String {
            let minutes = max(1, Int((seconds / 60).rounded()))
            guard minutes >= 60 else { return "\(minutes)m" }
            let rest = minutes % 60
            return "\(minutes / 60)h" + (rest > 0 ? " \(rest)m" : "")
        }
        if meeting.start <= now { return "now · \(span(meeting.end.timeIntervalSince(now))) left" }
        return "in \(span(meeting.start.timeIntervalSince(now)))"
    }
}
