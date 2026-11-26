import Foundation
import Network

/// A site whose name couldn't be looked up, or a page asked for with the
/// network gone, is as often as not there a moment later: the resolver had a
/// bad moment, the Wi-Fi was changing, a VPN was coming up. Chrome asks
/// again by itself; this did too little, saying "No site at that address."
/// and waiting. Taken from upstream Search (idea 1284), smaller.
///
/// Asked for again after 1, 3 and 8 seconds, and at once when the Mac's
/// network comes back. It stops at the first page that arrives, when the
/// tries are used up, or when the tab goes somewhere else. A lookup failure
/// is retried only for a site visited before: a word typed into the field
/// and taken for an address isn't a site that blinked. Nothing is watched
/// while nothing waits: the network monitor runs only with a retry pending.
@MainActor
final class LookupRetry {
    static let shared = LookupRetry()
    static let delays: [TimeInterval] = [1, 3, 8]
    static let trying = "Couldn't reach this site. Trying again…"

    private struct Pending {
        let url: URL
        var done: Int
        var work: DispatchWorkItem?
        weak var tab: Tab?
    }
    private var pending: [Tab.ID: Pending] = [:]
    private var monitor: NWPathMonitor?

    static func applies(to code: Int) -> (lookup: Bool, offline: Bool) {
        let lookup = code == NSURLErrorCannotFindHost || code == NSURLErrorDNSLookupFailed
        let offline = code == NSURLErrorNotConnectedToInternet || code == NSURLErrorNetworkConnectionLost
        return (lookup, offline)
    }

    /// A load failed. Returns the line to show while another try is coming,
    /// or nil when it isn't to be tried again.
    func failed(_ tab: Tab, url: URL?, code: Int, known: (String) -> Bool) -> String? {
        let kind = LookupRetry.applies(to: code)
        guard kind.lookup || kind.offline, let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host()?.lowercased()
        else { stop(tab); return nil }
        if kind.lookup && !known(host) { stop(tab); return nil }
        var entry = pending[tab.id].flatMap { $0.url == url ? $0 : nil } ?? Pending(url: url, done: 0, tab: tab)
        entry.work?.cancel()
        guard entry.done < LookupRetry.delays.count else { stop(tab); return nil }
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.again(tab)
        }
        entry.work = work
        pending[tab.id] = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + LookupRetry.delays[entry.done], execute: work)
        watch()
        return LookupRetry.trying
    }

    /// A page arrived, or the tab is going somewhere else.
    func stop(_ tab: Tab) {
        pending[tab.id]?.work?.cancel()
        pending[tab.id] = nil
        if pending.isEmpty { unwatch() }
    }

    private func again(_ tab: Tab) {
        guard var entry = pending[tab.id], tab.failure != nil else { stop(tab); return }
        entry.work?.cancel()
        entry.work = nil
        entry.done += 1
        pending[tab.id] = entry
        tab.go(to: entry.url)
    }

    private func watch() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        heardFirst = false
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.heard(up) }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    /// The first report is how things are, not a change; a later one that
    /// says the network is there is the network back.
    private var heardFirst = false
    private func heard(_ up: Bool) {
        defer { heardFirst = true }
        if up && heardFirst { networkBack() }
    }

    private func unwatch() {
        monitor?.cancel()
        monitor = nil
    }

    /// The network is back: every waiting page is asked for now.
    private func networkBack() {
        for (_, entry) in pending {
            guard let tab = entry.tab else { continue }
            again(tab)
        }
    }
}
