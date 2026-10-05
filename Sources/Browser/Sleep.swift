import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for half an hour gives its page
// back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
//
// When macOS says memory is short, the half hour shrinks: to five minutes on
// a warning, to nothing when it is critical.

extension Browser {
    /// How long a tab has to go without being looked at. Half an hour, or
    /// `sleep.after` in seconds — for the bench and the measurements.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        return set > 0 ? set : 30 * 60
    }

    /// Started once, at launch.
    func watchForSleep() {
        armSleep()

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                // Critical is every tab at once, and a picture of each —
                // at the moment there is least room for pictures — is
                // what it can least afford. They come back white instead.
                let critical = event.contains(.critical)
                self.sleepIdle(within: critical ? 0 : 5 * 60, pictured: !critical)
            }
        }
        source.resume()
        pressure = source
    }

    /// One timer, set for the moment the tab left longest will have been
    /// left long enough — not a look at every tab every minute, most of
    /// which found nothing (2 Oct 2026). A tab past due but kept awake,
    /// loading or playing, is looked at again in a minute; nothing to look
    /// at means the next look is a whole wait away. Set again after every
    /// look, whatever it found.
    private func armSleep() {
        dozing?.invalidate()
        let wait = Browser.sleepAfter
        let now = Date()
        let due = (tabs + parkedTabs)
            .filter { !$0.asleep && !$0.isBlank && $0.built != nil }
            .map { $0.touched.addingTimeInterval(wait) }
            .min() ?? now.addingTimeInterval(wait)
        let soon = min(60, max(5, wait / 4))
        let interval = due > now ? max(1, due.timeIntervalSince(now)) : soon
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first. The other profiles' too: a tab parked while it
    /// was loading or playing stayed awake, and nothing came back for it
    /// once it had finished (2 Oct 2026).
    func sleepIdle(within given: TimeInterval? = nil, pictured: Bool = true) {
        defer { armSleep() }
        guard prefs.sleepsTabs else { return }
        let wait = given ?? Browser.sleepAfter
        let now = Date()
        let idle = tabs
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab, pictured: pictured) }
        for tab in parkedTabs
        where now.timeIntervalSince(tab.touched) >= wait && awake(because: tab, parking: true) == nil {
            self.sleep(tab, parking: true, pictured: pictured)
        }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    ///
    /// `parking` is a profile being switched away from: on screen and
    /// pinned no longer mean anything there, and everything else still does.
    func awake(because tab: Tab, parking: Bool = false) -> String? {
        guard self.tab(tab.id) === tab else { return "closed" }
        if tab.id == activeID { return "on screen" }
        if parking, tabs.contains(where: { $0.id == tab.id }) { return "profile is back on screen" }
        if !parking, tab.pin != nil { return "pinned" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id || piped == tab.id { return "its video is out" }
        if Browser.startsOver(tab.address) { return "an app that would start over" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        // A sign-in window hands its answer back to the page that opened it.
        if active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Sites that are an app more than a page: put to sleep and rebuilt,
    /// they don't come back where they were — they start again, syncing
    /// every chat from the phone, which on WhatsApp is minutes (3 Oct
    /// 2026). They stay awake, as a pinned tab does.
    private static let startsOver: [String] = [
        "web.whatsapp.com", "web.telegram.org", "messages.google.com", "discord.com",
        "app.slack.com", "teams.microsoft.com", "www.messenger.com", "app.element.io",
    ]

    static func startsOver(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return startsOver.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime. `pictured` false
    /// skips the picture.
    func sleep(_ tab: Tab, parking: Bool = false, pictured: Bool = true, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab, parking: parking) {
            done?(reason)
            return
        }
        let revision = profileRevision
        let touched = tab.touched
        let navigation = tab.navigationID
        // Every asynchronous step must still belong to the same visit and
        // profile switch. A returned profile must never lose its live view.
        let current: () -> Bool = { [weak self, weak tab, weak page = tab.built] in
            guard let self, let tab, let page else { return false }
            return self.profileRevision == revision && tab.touched == touched
                && tab.navigationID == navigation && tab.built === page
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            guard current() else { done?("page changed"); return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab, parking: self.parked(tab, parking)) {
                done?(reason)
                return
            }
            guard pictured else {
                tab.sleep(picture: nil)
                done?("asleep")
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                guard current() else { done?("page changed"); return }
                if let reason = self.awake(because: tab, parking: self.parked(tab, parking)) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }

    /// Whether a tab being parked still is, a moment later. Each step above
    /// takes a beat, and a profile switched away from and straight back
    /// put the tab on screen again with "parked" still said of it — so the
    /// tab you were looking at went to sleep under you (2 Oct 2026).
    private func parked(_ tab: Tab, _ parking: Bool) -> Bool {
        parking && !tabs.contains { $0.id == tab.id }
    }
}
