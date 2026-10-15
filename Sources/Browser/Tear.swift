import AppKit
import WebKit

/// What a tab held out of the window looks like while it is still held: a
/// window-sized card with a picture of its page, where the new window will
/// open, following the pointer. Nothing is opened or moved until it is let
/// go of — so bringing it back over the row costs nothing and loses nothing.
@MainActor
final class TearPreview {
    private var panel: NSPanel?
    private let picture = NSImageView()

    /// `sidebar` is the column's width when the tabs are in one, so the page
    /// sits where it will sit; nil for the strip across the top.
    func show(_ tab: Tab, sidebar: CGFloat?, frame: NSRect) {
        let panel = self.panel ?? make()
        self.panel = panel
        panel.setFrame(frame, display: false)
        guard let ground = panel.contentView else { return }

        let page = sidebar.map { NSRect(x: $0, y: 0, width: frame.width - $0, height: frame.height) }
            ?? NSRect(x: 0, y: 0, width: frame.width, height: frame.height - Metrics.strip)
        picture.frame = page
        picture.image = nil
        if let web = tab.built {
            let shot = WKSnapshotConfiguration()
            shot.snapshotWidth = NSNumber(value: Double(min(page.width, 900)))
            web.takeSnapshot(with: shot) { [weak self] image, _ in
                MainActor.assumeIsolated { self?.picture.image = image }
            }
        }
        if picture.superview !== ground { ground.addSubview(picture) }

        // In quickly and from nearly nothing, so it reads as the tab lifting
        // off rather than a window arriving.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 0.94
        }
    }

    func move(to frame: NSRect) {
        panel?.setFrameOrigin(frame.origin)
    }

    /// Following the pointer, and seen only where a window would open — not
    /// over another window's row, where the tab goes in among its tabs.
    func over(_ open: Bool, frame: NSRect) {
        guard let panel else { return }
        panel.setFrameOrigin(frame.origin)
        let alpha: CGFloat = open ? 0.94 : 0
        guard panel.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = alpha
        }
    }

    func hide() {
        panel?.orderOut(nil)
        picture.image = nil
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let ground = NSView()
        ground.wantsLayer = true
        ground.layer?.backgroundColor = Palette.NS.ground.cgColor
        ground.layer?.cornerRadius = 10
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true
        ground.layer?.borderWidth = 1
        ground.layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        panel.contentView = ground

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignTop
        return panel
    }
}

/// A tab held out over another app's window becomes the Mac's own drag of
/// its address, so it can be dropped into Slack, Notes, Mail or a Finder
/// window as a link — the way Safari and Chrome let a tab go. The tab stays
/// where it was. Let go of over nothing that takes a link, it gets a window
/// of its own after all; over one of this app's windows, it moves there.
@MainActor
final class TabDragOut: NSObject, NSDraggingSource {
    static let shared = TabDragOut()
    /// The tab on its way out, and the window it is leaving.
    private(set) var tab: Tab?
    private(set) weak var from: Browser?

    var active: Bool { tab != nil }

    /// Over a window that belongs to another app, at the pointer.
    static func overOtherApp() -> Bool {
        let at = NSEvent.mouseLocation
        guard let top = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Window bounds run down from the top of the first screen.
        let point = CGPoint(x: at.x, y: top - at.y)
        let me = ProcessInfo.processInfo.processIdentifier
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point)
            else { continue }
            // The topmost window under the pointer decides.
            return (window[kCGWindowOwnerPID as String] as? Int32) != me
        }
        return false
    }

    /// Starts the drag from the window the tab is held in, on the drag
    /// event under way.
    func begin(_ tab: Tab, from browser: Browser) -> Bool {
        guard let url = tab.pending ?? tab.address, ["http", "https"].contains(url.scheme ?? ""),
              let view = browser.window?.contentView,
              let event = NSApp.currentEvent, event.type == .leftMouseDragged
        else { return false }
        self.tab = tab
        from = browser

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let label = TabDragOut.picture(title: tab.title.isEmpty ? Address.pretty(url) : tab.title, icon: tab.icon)
        let at = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 16, y: at.y - label.size.height / 2, width: label.size.width, height: label.size.height), contents: label)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : [.copy, .link, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let tab = self.tab
        let from = self.from
        self.tab = nil
        self.from = nil
        guard let tab, let from else { return }
        from.droppedOut(tab, at: screenPoint, taken: operation != [])
    }

    /// The tab, small, as it travels: its icon and its title on a pill.
    private static func picture(title: String, icon: NSImage?) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = NSAttributedString(string: String(title.prefix(48)), attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let width = min(320, ceil(text.size().width)) + 44
        let size = NSSize(width: width, height: 28)
        return NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            icon?.draw(in: NSRect(x: 9, y: 6, width: 16, height: 16))
            text.draw(with: NSRect(x: 32, y: 7, width: width - 40, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            return true
        }
    }
}
