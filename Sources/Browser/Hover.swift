import AppKit
import SwiftUI

/// Rest on a tab and a small card says what it is: the whole title, the
/// site, and whether it is asleep or making a sound — Chrome's hover card.
/// What a pinned square or a cut-off title can't say for itself.
///
/// It waits half a second the first time, so passing over the tabs on the
/// way somewhere says nothing; once one is up, the next tab's comes at once,
/// with no fade, so running down the column reads them off.
@MainActor
final class HoverCard {
    private var panel: NSPanel?
    private var host: NSHostingView<Face>?
    private var waiting: DispatchWorkItem?
    private var leaving: DispatchWorkItem?
    /// When a card was last put away: back on a tab soon after, the next
    /// one comes at once.
    private var gone = Date.distantPast
    private weak var showing: Tab?

    func hover(_ tab: Tab, in browser: Browser) {
        leaving?.cancel()
        waiting?.cancel()
        // Not while a tab is being dragged, nor over the one being renamed.
        guard NSEvent.pressedMouseButtons == 0, browser.editingTab != tab.id, let window = browser.window else { return }
        let warm = panel?.isVisible == true || Date().timeIntervalSince(gone) < 0.4
        if warm {
            show(tab, in: browser, window: window, fade: false)
            return
        }
        let work = DispatchWorkItem { [weak self, weak tab, weak browser] in
            guard let self, let tab, let browser, let window = browser.window,
                  NSEvent.pressedMouseButtons == 0
            else { return }
            show(tab, in: browser, window: window, fade: true)
        }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The pointer is off a tab. A moment's grace, so going from one tab to
    /// the next doesn't put the card away in between.
    func leave() {
        waiting?.cancel()
        leaving?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func hide() {
        waiting?.cancel()
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        showing = nil
        gone = Date()
    }

    private func show(_ tab: Tab, in browser: Browser, window: NSWindow, fade: Bool) {
        let panel = self.panel ?? make()
        self.panel = panel
        showing = tab
        let face = Face(
            title: tab.title.isEmpty ? tab.label : tab.title,
            site: tab.address.map(Address.pretty) ?? "",
            state: tab.muted ? "Muted" : tab.noisy ? "Playing sound" : tab.asleep ? "Asleep — opens again when you pick it" : nil
        )
        host?.rootView = face
        let size = host?.fittingSize ?? NSSize(width: 260, height: 54)

        // Beside the column, level with the pointer; under the strip, at it.
        let at = NSEvent.mouseLocation
        let frame = window.frame
        var origin: NSPoint
        if browser.prefs.sidebar {
            origin = NSPoint(x: frame.minX + browser.prefs.sideWidth + 8, y: at.y - size.height / 2)
        } else {
            origin = NSPoint(x: at.x - 24, y: frame.maxY - Metrics.strip - 6 - size.height)
        }
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(screen.minX + 4, origin.x), screen.maxX - size.width - 4)
            origin.y = min(max(screen.minY + 4, origin.y), screen.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }

        guard fade, !panel.isVisible else {
            panel.alphaValue = 1
            panel.orderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 1
        }
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Flat, like the rows it speaks for: no shadow lifting it off the page.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        let host = NSHostingView(rootView: Face(title: "", site: "", state: nil))
        panel.contentView = host
        self.host = host
        return panel
    }

    struct Face: View {
        let title: String
        let site: String
        let state: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !site.isEmpty {
                    Text(site)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let state {
                    Text(state)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 260, alignment: .leading)
            // The live tab's own grey and corner — no border, no shadow.
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
