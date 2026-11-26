import AppKit

// The traffic lights, where a Mac app with a toolbar has them — set in from the
// corner and centred in the strip's height — without the toolbar.
//
// An empty toolbar is the public way to move them, and it was how this window
// did it. On macOS 26 a toolbar also rounds the window's corners almost twice
// as much: 31.5 points against 17.5 for a window without one, measured, and
// 17.5 is what Claude's window and the Finder have. So the window has no
// toolbar, and the three buttons are put where one would have put them, by
// hand — which is how Claude's own window does it. AppKit lays its title bar
// out again whenever it sees fit (a resize, full screen, the window becoming
// key), so every time it does, the buttons are put back.

@MainActor
final class Lights: NSObject {
    /// Where the close button's centre goes, from the window's top-left: where
    /// a unified toolbar put it, which Metrics.lights and sideLights are
    /// measured from.
    static let centre = CGPoint(x: 26, y: 26)

    private static var kept: [ObjectIdentifier: Lights] = [:]

    /// The column folded to a rail (⌘S): the three stood one over another,
    /// centred in it, instead of side by side.
    static func stand(_ window: NSWindow, _ upright: Bool) {
        guard let lights = kept[ObjectIdentifier(window)], lights.upright != upright else { return }
        lights.upright = upright
        lights.place()
    }
    private var upright = false

    /// Starts looking after a window's lights, once. `moved` hears each time
    /// they have been put in place.
    static func keep(_ window: NSWindow, moved: @escaping () -> Void) {
        guard kept[ObjectIdentifier(window)] == nil else { return }
        kept[ObjectIdentifier(window)] = Lights(window, moved: moved)
    }

    private weak var window: NSWindow?
    private let moved: () -> Void
    private var placing = false
    /// AppKit's own spacing between the three, read once from its first
    /// layout and kept. Read again on every pass, it was caught while AppKit
    /// was halfway through putting them back after a resize — one button
    /// moved, the next not yet — and the three closed up from 23 points apart
    /// to 13, on top of each other, a spacing each later pass then copied
    /// from the one before. Reproduced with ./bench resize, 23 Sep 2026.
    private let spacing: CGFloat

    private init(_ window: NSWindow, moved: @escaping () -> Void) {
        self.window = window
        self.moved = moved
        let row = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { window.standardWindowButton($0) }
        let measured = row.count == 2 ? row[1].frame.minX - row[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20
        super.init()
        let centre = NotificationCenter.default
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
        ] {
            centre.addObserver(self, selector: #selector(place), name: name, object: window)
        }
        // Coming back from another app, AppKit redraws the buttons for the
        // active state and can lay them out again as it does.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            centre.addObserver(self, selector: #selector(place), name: name, object: nil)
        }
        watch()
        place()
    }

    /// The title bar's views being watched for moves.
    private var watched: [ObjectIdentifier] = []

    /// The title bar's own views moving is the surest sign AppKit has just
    /// laid them out again. AppKit sometimes builds its title bar afresh — out
    /// of full screen, after the buttons were hidden and shown — and the new
    /// views were never watched, so a later layout left the three wherever
    /// AppKit had put them, scattered (17 Nov 2026). Whatever views are there
    /// now are the ones watched.
    private func watch() {
        let buttons = self.buttons
        guard let bar = buttons.first?.superview, let container = bar.superview else { return }
        let views = [container, bar] + buttons
        let ids = views.map(ObjectIdentifier.init)
        guard ids != watched else { return }
        let centre = NotificationCenter.default
        centre.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        for view in views {
            view.postsFrameChangedNotifications = true
            centre.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: view)
        }
        watched = ids
    }

    private var again = false

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    @objc private func place() {
        // Full screen keeps its title bar in a window of its own, laid out by
        // macOS; it is left to it.
        guard !placing, let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return }
        placing = true
        defer { placing = false }
        watch()
        // AppKit moves the three one at a time; the pass that answers the
        // first move can run before the last. One more look on the next turn
        // puts right whatever moved after.
        if !again {
            again = true
            DispatchQueue.main.async { [weak self] in
                // Still marked, so this look does not ask for another.
                self?.place()
                self?.again = false
            }
        }

        // A title bar as tall as the strip, so the buttons can sit lower in it.
        // Upright, the bar is grown to hold all three.
        let height = upright ? Metrics.railLights : Metrics.strip
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        // Only the row moves; the spacing is AppKit's, from its first layout.
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = upright
                ? NSPoint(
                    x: Metrics.rail / 2 - size.width / 2,
                    y: bar.bounds.height - 22 - size.height / 2 - CGFloat(index) * spacing
                )
                : NSPoint(
                    x: Lights.centre.x - size.width / 2 + CGFloat(index) * spacing,
                    y: bar.bounds.height - Lights.centre.y - size.height / 2
                )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        moved()
    }
}
