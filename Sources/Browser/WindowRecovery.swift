import AppKit

/// AppKit also owns offscreen rendering windows, popovers and visual-effect
/// windows. None of those is evidence that a browser is on the screen.
@MainActor
enum WindowRecovery {
    static func accepts(_ window: NSWindow) -> Bool {
        // canBecomeMain is false while a normal window is hidden or minimized.
        // Eligibility must survive exactly the states we need to recover.
        !(window is NSPanel) && window.styleMask.contains([.titled, .closable, .resizable])
            && window.canBecomeKey && window.contentView != nil
    }

    static var windows: [NSWindow] {
        Browser.every.allObjects.compactMap(\.window).filter(accepts)
    }

    static var front: NSWindow? {
        let owned = windows
        // Keep the window the person was using, including a private one.
        // If everything is put away, prefer the main window with its session.
        return NSApp.orderedWindows.first { candidate in owned.contains { $0 === candidate } }
            ?? owned.first { $0 === Links.window }
            ?? owned.first
    }

    /// Leave a window that can be reached alone. An unplugged display or a
    /// custom title-bar drag can otherwise leave an apparently visible window
    /// entirely outside the desktop, and ordering it front changes nothing.
    static func reachableFrame(_ frame: NSRect, screens: [NSRect], preferred: NSRect?) -> NSRect {
        let finite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        let title = NSRect(x: frame.minX, y: frame.maxY - 32, width: frame.width, height: 32)
        if finite, frame.width >= 100, frame.height >= 100,
           screens.contains(where: {
               let overlap = title.intersection($0)
               return overlap.width >= 80 && overlap.height >= 16
           }) { return frame }
        guard let screen = preferred ?? screens.first else { return frame }
        let size = NSSize(width: min(finite && frame.width >= 100 ? frame.width : 1180, screen.width),
                          height: min(finite && frame.height >= 100 ? frame.height : 780, screen.height))
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func keepOnScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let frame = reachableFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame),
                                   preferred: NSScreen.main?.visibleFrame)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    static func show(_ window: NSWindow) {
        WindowJournal.record("recover-before", window: window)
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        keepOnScreen(window)
        window.alphaValue = 1
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        WindowJournal.record("recover-after", window: window)
    }
}

/// Keep SwiftUI's window delegate. Observations track the lifetime without
/// replacing the delegate that owns the scene or retaining a closed browser.
@MainActor
final class WindowWatch {
    private var tokens: [NSObjectProtocol] = []

    init(_ window: NSWindow, browser: Browser) {
        WindowJournal.record("attach", window: window)
        let centre = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            tokens.append(centre.addObserver(forName: name, object: window, queue: .main) { [weak window] note in
                MainActor.assumeIsolated {
                    if let window { WindowJournal.record(note.name.rawValue, window: window) }
                }
            })
        }
        tokens.append(centre.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak browser, weak window] _ in
            MainActor.assumeIsolated {
                guard let browser, let window, browser.window === window else { return }
                WindowJournal.record("close", window: window, stack: Thread.callStackSymbols)
                // The final session flush still needs every window's frame.
                // Quitting ends these windows together; it isn't closing one.
                guard !Browser.quitting else { return }
                // SwiftUI dismisses the scene. Ordering this old NSWindow front
                // does not present that scene again; reopen it with openWindow.
                browser.window = nil
                if Links.window === window { Links.window = nil }
                if browser.isPrivate { browser.endPrivate() }
                else if browser.isTorn { browser.endTorn() }
                browser.windowWatch = nil
            }
        })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

/// A small, local record for failures that don't crash. No titles, addresses,
/// page contents or keystrokes; two files capped at 256 KB apiece.
enum WindowJournal {
    private static let queue = DispatchQueue(label: "browser.window-log", qos: .utility)

    @MainActor
    static func record(_ event: String, window: NSWindow? = nil, stack: [String] = []) {
        var line = "\(Date()) pid=\(ProcessInfo.processInfo.processIdentifier) \(event) active=\(NSApp.isActive) hidden=\(NSApp.isHidden)"
        if let window {
            line += " window=\(window.windowNumber) class=\(type(of: window)) visible=\(window.isVisible) mini=\(window.isMiniaturized) occluded=\(!window.occlusionState.contains(.visible)) space=\(window.isOnActiveSpace) alpha=\(window.alphaValue) frame=\(NSStringFromRect(window.frame)) fullscreen=\(window.styleMask.contains(.fullScreen)) content=\(window.contentView != nil)"
        }
        line += "\n" + (stack.isEmpty ? "" : stack.prefix(24).joined(separator: "\n") + "\n")
        let data = Data(line.utf8)
        let file = Store.file("windows.log")
        queue.async {
            let files = FileManager.default
            try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? files.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > 256 * 1024 {
                let previous = file.deletingLastPathComponent().appendingPathComponent("windows.previous.log")
                try? files.removeItem(at: previous)
                try? files.moveItem(at: file, to: previous)
            }
            if !files.fileExists(atPath: file.path) { files.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch {}
        }
    }
}
