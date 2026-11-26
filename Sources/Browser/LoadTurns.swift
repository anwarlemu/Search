import AppKit
import WebKit

/// Pages out of sight load a few at a time (from upstream Search, #1529).
///
/// A page loading runs its scripts on a processor of its own, and a run of
/// links opened behind the one you read had every page wanting a whole
/// processor at once: the window's own thread then waited its turn with
/// them, and scrolling or a swipe stuttered. So a page out of sight starts
/// loading only while fewer than `at` others out of sight are; the rest
/// wait, in the order asked. A page in sight never waits, and one that comes
/// into sight while waiting starts at once. A turn ends as the page stops
/// loading, two seconds on if it never started, or twenty seconds on
/// whatever it is doing, so a page that never says it's done can't hold up
/// the rest.
@MainActor
final class LoadTurns {
    static let shared = LoadTurns()

    /// Half the Mac's processors, from two to six.
    static let at = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// A load: true when it asked for a page, false when it found it was no
    /// longer wanted.
    typealias Load = () -> Bool

    private final class Turn {
        weak var view: WKWebView?
        var watch: NSKeyValueObservation?
        var started = false
        var ends: [DispatchWorkItem] = []
        init(_ view: WKWebView) { self.view = view }
    }

    private struct Waiting {
        weak var view: WKWebView?
        let load: Load
    }

    private var turns: [ObjectIdentifier: Turn] = [:]
    private var waiting: [Waiting] = []

    static func inSight(_ view: WKWebView) -> Bool { view.window != nil }

    /// `load` for `view`: now, if it is in sight or a turn is free;
    /// otherwise once one is. Asked again, it replaces the one waiting.
    func start(_ view: WKWebView, _ load: @escaping Load) {
        waiting.removeAll { $0.view == nil || $0.view === view }
        finish(ObjectIdentifier(view), next: false)
        if Self.inSight(view) {
            _ = load()
        } else if turns.count < Self.at {
            run(view, load)
        } else {
            waiting.append(Waiting(view: view, load: load))
        }
        next()
    }

    /// The view came into sight: what it waits for, now, and the turn it
    /// held given to another.
    func shown(_ view: WKWebView) {
        finish(ObjectIdentifier(view))
        guard let index = waiting.firstIndex(where: { $0.view === view }) else { return }
        _ = waiting.remove(at: index).load()
    }

    private func run(_ view: WKWebView, _ load: Load) {
        let id = ObjectIdentifier(view)
        let turn = Turn(view)
        turns[id] = turn
        let key = ObjectIdentifier(turn)
        turn.watch = view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, let turn = self.turns[id], ObjectIdentifier(turn) == key else { return }
                if view.isLoading { turn.started = true } else if turn.started { self.finish(id) }
            }
        }
        for (after, unlessStarted) in [(2.0, true), (20.0, false)] {
            let end = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let turn = self.turns[id], ObjectIdentifier(turn) == key,
                          !(unlessStarted && turn.started) else { return }
                    self.finish(id)
                }
            }
            turn.ends.append(end)
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: end)
        }
        if !load() { finish(id) } else if view.isLoading { turn.started = true }
    }

    private func finish(_ id: ObjectIdentifier, next more: Bool = true) {
        guard let turn = turns.removeValue(forKey: id) else { return }
        turn.watch?.invalidate()
        turn.ends.forEach { $0.cancel() }
        if more { next() }
    }

    private func next() {
        for (id, turn) in turns where turn.view == nil { finish(id, next: false) }
        while turns.count < Self.at, !waiting.isEmpty {
            let first = waiting.removeFirst()
            guard let view = first.view else { continue }
            if Self.inSight(view) { _ = first.load() } else { run(view, first.load) }
        }
    }
}
