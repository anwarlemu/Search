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
