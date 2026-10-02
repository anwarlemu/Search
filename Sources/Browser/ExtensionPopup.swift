import AppKit
import WebKit

// An extension's popup, in a popover of the browser's own.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions — but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view, in a popover that hangs from the button.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    /// The popup as WebKit is told about it: a page it can find, belonging
    /// to the browser's window — Chrome gives a popup no window of its own,
    /// so "the current window" from a popup is the browser's, and so is the
    /// last focused one.
    private var page: PopupPage?
    private(set) var extensionID: String?
    /// Whose popup it is, for the line that says it couldn't open.
    private var extensionName = ""

    /// The popup's web view, while one is up — for the bench.
    var view: WKWebView? { web }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        // Sized the way Chrome sizes a popup (see preferred), unseen, while
        // the popover stands at a guess; then shown. It has to be in the
        // window meanwhile: WebKit suspends a page that is in none.
        // One opened before stands at its last size from the first frame,
        // page and all — no guess, no fade, no jump — and is only resized
        // if its measure comes out more than a few points different (see
        // apply) (2 Oct 2026).
        let remembered = ExtensionPopup.lastSize(for: context.uniqueIdentifier)
        let size = remembered ?? NSSize(width: 360, height: 240)
        let web = WKWebView(frame: NSRect(origin: .zero, size: remembered == nil ? NSSize(width: 25, height: 25) : size), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        // White behind the page, as Chrome paints a popup: many leave their
        // background unset, and their dark text over the popover's dark
        // material would vanish.
        web.alphaValue = remembered == nil ? 0 : 1
        if remembered != nil { web.autoresizingMask = [.width, .height] }
        web.load(URLRequest(url: url))

        let stage = NSView(frame: NSRect(origin: .zero, size: size))
        stage.addSubview(web)
        let host = NSViewController()
        host.view = stage
        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        extensionName = context.webExtension.displayName ?? "the extension"
        let page = PopupPage(web: web)
        self.page = page
        Extensions.shared.controller.didOpenTab(page)

        shown = remembered != nil
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
        // Measured when the document is built (see below) or has loaded;
        // a page slow to do either is measured anyway after a moment, and
        // shown regardless a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover, self.watching == 0 else { return }
            self.follow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.reveal()
        }
    }

    /// Each extension's popup size, kept across launches, so the next
    /// opening starts there.
    private static func lastSize(for id: String) -> NSSize? {
        guard let pair = Store.settings.array(forKey: "extensions.popup.\(id)") as? [Double], pair.count == 2 else { return nil }
        return NSSize(width: pair[0], height: pair[1])
    }
    private static func remember(_ size: NSSize, for id: String) {
        Store.settings.set([size.width, size.height], forKey: "extensions.popup.\(id)")
    }
    private var shown = false

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let stage = popover?.contentViewController?.view else { return }
        shown = true
        web.frame = NSRect(origin: .zero, size: popover?.contentSize ?? stage.bounds.size)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
    }

    /// From the page's first load: sized, then measured again each time its
    /// document changes size — a list filled in by a reply from the worker
    /// — as the page itself reports it (see changed). A timer measured
    /// four times a second for six seconds before, forcing a layout each
    /// time whether anything had moved or not (2 Oct 2026).
    private func follow() {
        firstMeasure()
        watch()
    }

    func close() {
        let closing = popover
        forget()
        closing?.performClose(nil)
    }

    /// Tells WebKit the popup's window and tab are gone.
    private func forget() {
        if let page { Extensions.shared.controller.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        measured = nil
        watching = 0
    }


    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still the 25-point square: the width the page names for itself if it
    /// names one, else its narrowest (min-content — what is positioned off
    /// to the side doesn't count), else, for a page with next to no width
    /// of its own, what its content spans; then, laid out at that width,
    /// the height it names or spans. Nothing of it is left on the page.
    static let preferred = """
    () => {
      const d = document.documentElement;
      if (!d) return null;
      const m = window.__searchSizing || (window.__searchSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const box = d.getBoundingClientRect();
      // A width the page sets for itself shows as one the view doesn't
      // have; one equal to the view is either filling it or the width it
      // was given last time, remembered.
      let w;
      if (Math.abs(box.width - innerWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - innerWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      w = Math.min(800, Math.max(25, Math.ceil(w)));
      d.style.setProperty("width", w + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h)))];
    }
    """

    /// The document is built — DOMContentLoaded, the moment Chrome sizes a
    /// popup, before the page's scripts look at the room they have (Proton
    /// Pass takes whatever size it finds then for good). WebKit tells a
    /// navigation delegate that has this method; the configuration
    /// extension pages share can't be given a script of our own.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        firstMeasure()
    }

    /// Measured — while still the 25-point square and unseen, or at the
    /// size remembered — and shown at the size found.
    private func firstMeasure() {
        guard let web, measured == nil else { return }
        web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, self.measured == nil else { return }
                guard let pair = value as? [Double], pair.count == 2 else { return }
                self.measured = Date()
                self.apply(NSSize(width: pair[0], height: pair[1]))
            }
        }
    }

    /// When the page was first measured; nil until it has been.
    private var measured: Date?

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        // A popup already in view at its remembered size isn't nudged by
        // a point or two — that is the jump remembering is there to spare.
        let slack: CGFloat = shown ? 4 : 1
        if abs(size.width - popover.contentSize.width) > slack || abs(size.height - popover.contentSize.height) > slack {
            // The popover takes its size from its view controller, and goes
            // back to it: both are told.
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
        }
        if let id = extensionID { ExtensionPopup.remember(popover.contentSize, for: id) }
        reveal()
    }

    /// Settles the moment the document, its body or the body's first
    /// element changes size — the shells popups build themselves in — a
    /// breath after the last change in a burst. The first notice a
    /// ResizeObserver gives is of the sizes as they are, not a change. In
    /// the app's own world, so the page sees nothing of it.
    static let changed = """
    return new Promise((done) => {
      const d = document.documentElement;
      if (!d || typeof ResizeObserver !== "function") return;
      let timer = null, primed = false;
      const o = new ResizeObserver(() => {
        if (!primed) { primed = true; return; }
        clearTimeout(timer);
        timer = setTimeout(() => { o.disconnect(); done(true); }, 60);
      });
      o.observe(d);
      if (document.body) { o.observe(document.body); if (document.body.firstElementChild) o.observe(document.body.firstElementChild); }
    });
    """

    /// Which watch is current: a page the popup goes on to (a load after
    /// the first) starts a new one, and the old one's word is let go.
    private var watching = 0

    /// Waits for the page to change size, measures, and waits again.
    private func watch() {
        guard let web else { return }
        watching += 1
        let token = watching
        web.callAsyncJavaScript(ExtensionPopup.changed, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, web === self.web, token == self.watching, (try? result.get()) != nil else { return }
                self.grow()
                self.watch()
            }
        }
    }

    /// Measured again as the page builds itself, the way Chrome measures on
    /// each layout: for its first two seconds the popup follows it either
    /// way, after that it only grows — so a page that settles doesn't set
    /// it rocking.
    private func grow() {
        guard let measured else { return firstMeasure() }
        guard shown, let web, let popover else { return }
        web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, let pair = value as? [Double], pair.count == 2 else { return }
                let now = popover.contentSize
                var wanted = NSSize(width: pair[0], height: pair[1])
                if Date().timeIntervalSince(measured) > 2 {
                    wanted = NSSize(width: max(now.width, wanted.width), height: max(now.height, wanted.height))
                }
                self.apply(wanted)
            }
        }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { follow() }

    /// A page that won't load — gone from the extension, refused by it —
    /// was an empty popover for five seconds. Said, and closed (2 Oct 2026).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }

    private func failed(_ webView: WKWebView, _ error: Error) {
        // A load the page itself cut short — window.close(), a link out —
        // isn't a failure.
        guard webView === web, (error as NSError).code != NSURLErrorCancelled else { return }
        Extensions.shared.browser?.announce("Couldn't open \(extensionName)'s popup")
        close()
    }

    /// A link that asks for a new window becomes a tab, and the popup goes —
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { Extensions.shared.browser?.open(url, foreground: true) }
        close()
        return nil
    }

    /// Only for the popover that is up: closing the last one animates, and
    /// its notification can land after the next one has opened.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        forget()
    }
}

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs — which is where Chrome puts a popup too.
@available(macOS 15.4, *)
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?

    init(web: WKWebView) { self.web = web }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}

