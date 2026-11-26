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
            present(tab, in: browser, window: window, fade: false)
            return
        }
        let work = DispatchWorkItem { [weak self, weak tab, weak browser] in
            guard let self, let tab, let browser, let window = browser.window,
                  NSEvent.pressedMouseButtons == 0
            else { return }
            present(tab, in: browser, window: window, fade: true)
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
        asked = nil
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        showing = nil
        gone = Date()
    }

    /// A pin you aren't on gets a picture of its page on its card, and what
    /// is waiting in it, as upstream Search's pin previews (idea 1205): a
    /// glance at Gmail or Calendar without going there. The picture first,
    /// so the card comes in at its size. A private tab's page is never
    /// pictured outside it.
    private func present(_ tab: Tab, in browser: Browser, window: NSWindow, fade: Bool) {
        guard tab.pin != nil, tab.id != browser.activeID, !tab.shy else {
            show(tab, in: browser, window: window, fade: fade, picture: nil)
            return
        }
        asked = tab.id
        tab.glance(width: HoverCard.pictured) { [weak self, weak tab, weak browser, weak window] image in
            MainActor.assumeIsolated {
                guard let self, let tab, let browser, let window, self.asked == tab.id,
                      browser.pointed == tab.id else { return }
                self.show(tab, in: browser, window: window, fade: fade, picture: image)
            }
        }
    }
    /// The pin a picture is on its way for.
    private var asked: Tab.ID?
    /// A pictured card's width.
    static let pictured: CGFloat = 260

    private func show(_ tab: Tab, in browser: Browser, window: NSWindow, fade: Bool, picture: NSImage?) {
        let panel = self.panel ?? make()
        self.panel = panel
        showing = tab
        let title = tab.title.isEmpty ? tab.label : tab.title
        let site = tab.address.map(Address.pretty) ?? ""
        let state = tab.muted ? "Muted" : tab.noisy ? "Playing sound" : tab.asleep ? "Asleep — opens when picked" : nil
        let unread = tab.pin != nil ? tab.unread : nil
        let face = Face(title: title, site: site, state: unread.map { "\($0) unread" } ?? state,
                        width: picture == nil ? HoverCard.width(title: title, site: site, state: state) : HoverCard.pictured,
                        picture: picture)
        host?.rootView = face
        let size = host?.fittingSize ?? NSSize(width: 260, height: 54)

        // Beside the column, level with the pointer; under the strip, at it.
        let at = NSEvent.mouseLocation
        let frame = window.frame
        var origin: NSPoint
        if browser.prefs.sidebar {
            origin = NSPoint(x: frame.minX + (browser.prefs.bare ? Metrics.rail : browser.prefs.sideWidth) + 8, y: at.y - size.height / 2)
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

    /// As wide as its longest line wants, and no wider: a short title gets
    /// a short card. Past 240 the title wraps and the site is cut in the
    /// middle; under 120 the card would look like a scrap.
    static func width(title: String, site: String, state: String?) -> CGFloat {
        let lines: [(String, NSFont)] = [
            (title, .systemFont(ofSize: 12.5, weight: .medium)),
            (site, .systemFont(ofSize: 11.5)),
            (state ?? "", .systemFont(ofSize: 11)),
        ]
        let widest = lines.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).width }.max() ?? 0
        return min(240, max(120, ceil(widest) + 20))
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
        let host = NSHostingView(rootView: Face(title: "", site: "", state: nil, width: 120, picture: nil))
        panel.contentView = host
        self.host = host
        return panel
    }

    struct Face: View {
        let title: String
        let site: String
        let state: String?
        let width: CGFloat
        let picture: NSImage?

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: (width * 0.62).rounded(), alignment: .top)
                        .clipped()
                }
                words
            }
            .frame(width: width, alignment: .leading)
            // The live tab's own grey and corner — no border, no shadow.
            .background(Palette.wash)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        private var words: some View {
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
            .frame(width: width, alignment: .leading)
        }
    }
}
